// GoalsTool.swift — tool `goals`: el chat declara metas YA (sin esperar al ciclo
// nocturno) y gestiona su check-in. Leer y registrar la respuesta del dueño a un
// check-in = aferente (lo dijo él en la conversación); declarar, cambiar la
// cadencia y marcar lograda = eferente (ask). Tras cada cambio el shell
// re-sincroniza las notificaciones locales (`onChange`).

import Foundation

public struct GoalsTool: SensorimotorTool {
    private let otherModel: OtherModel
    private let onChange: @Sendable () async -> Void

    public init(otherModel: OtherModel, onChange: @escaping @Sendable () async -> Void = {}) {
        self.otherModel = otherModel
        self.onChange = onChange
    }

    private static let readOps: Set<String> = ["list", "record_checkin"]
    private static let cadences = ProactiveCadence.allCases.map { JSONValue.string($0.rawValue) }

    public var spec: ToolSpec {
        let checkinSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "cadence": .object(["type": .string("string"), "enum": .array(Self.cadences)]),
                "hour": .object(["type": .string("integer"), "description": .string("0-23, hora local (default 20).")]),
                "minute": .object(["type": .string("integer"), "description": .string("0-59 (default 0).")]),
                "weekday": .object(["type": .string("integer"),
                                    "description": .string("Solo weekly: 1=domingo … 7=sábado.")]),
            ]),
        ])
        return .client(
            name: "goals",
            description: """
                Metas del dueño. Cuando diga "quiero X", "mi meta es Y" o "quiero llegar a Z", \
                regístrala YA con declare (no esperes a la noche) y ofrécele un check-in: tú le \
                preguntas con la cadencia elegida (daily/weekdays/weekly a HH:mm) si avanzó. \
                Acciones: list; declare {statement, predicate?, checkin?}; set_checkin {goal_id, \
                cadence, hour?, minute?, weekday?}; clear_checkin {goal_id}; record_checkin \
                {goal_id, answer: yes|partial|no|skipped, note?} cuando el dueño te cuente cómo \
                le fue; mark_achieved {goal_id}. predicate (opcional) usa el vocabulario cerrado: \
                workouts_per_week{value}, reminders_overdue_at_most{value}, \
                sleep_hours_at_least{hours,last_days}, calendar_has_free_slot{min_minutes,within_days}, \
                days_since_last_mention_at_most{topic,days}, progress_check_in{every_days}; sin \
                predicate se usa progress_check_in. list y record_checkin no piden confirmación; \
                el resto la pide el harness: llama la tool directo, sin preguntar antes en el chat.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array(["list", "declare", "set_checkin", "clear_checkin", "record_checkin",
                                        "mark_achieved"].map { .string($0) }),
                    ]),
                    "statement": .object(["type": .string("string"),
                                          "description": .string("La meta en palabras del dueño (declare).")]),
                    "predicate": .object(["type": .string("object"),
                                          "description": .string("Predicado observable {kind, ...} (declare).")]),
                    "checkin": checkinSchema,
                    "goal_id": .object(["type": .string("string")]),
                    "cadence": .object(["type": .string("string"), "enum": .array(Self.cadences)]),
                    "hour": .object(["type": .string("integer")]),
                    "minute": .object(["type": .string("integer")]),
                    "weekday": .object(["type": .string("integer")]),
                    "answer": .object(["type": .string("string"),
                                       "enum": .array(CheckInAnswer.allCases.map { .string($0.rawValue) })]),
                    "note": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("action")]),
                "additionalProperties": .bool(false),
            ]))
    }

    public func kind(for input: JSONValue) -> ToolKind {
        Self.readOps.contains(input["action"]?.stringValue ?? "") ? .afferent : .efferent
    }

    public func confirmationSummary(for input: JSONValue) -> String {
        let goal = input["goal_id"]?.stringValue ?? "?"
        switch input["action"]?.stringValue {
        case "declare":
            let statement = input["statement"]?.stringValue ?? "(sin enunciado)"
            let checkIn = input["checkin"].flatMap { Self.cadence(from: $0) }.flatMap { $0.isActive ? $0 : nil }
            return "Registrar meta '\(statement)'" + (checkIn.map { " y preguntarte \($0.phrase)" } ?? "")
        case "set_checkin":
            guard let checkIn = Self.cadence(from: input), checkIn.isActive else {
                return "Quitar el check-in de la meta \(goal)"
            }
            return "Preguntarte por la meta \(goal) \(checkIn.phrase)"
        case "clear_checkin":
            return "Quitar el check-in de la meta \(goal)"
        case "mark_achieved":
            return "Marcar como lograda la meta \(goal)"
        default:
            return "goals: \(operation(for: input))"
        }
    }

    public func execute(_ input: JSONValue) async -> ToolResult {
        guard let action = input["action"]?.stringValue else {
            return Self.error("falta 'action'.")
        }
        switch action {
        case "list": return await list()
        case "declare": return await declare(input)
        case "set_checkin": return await setCheckIn(input)
        case "clear_checkin": return await clearCheckIn(input)
        case "record_checkin": return await recordCheckIn(input)
        case "mark_achieved": return await markAchieved(input)
        default: return Self.error("acción de goals desconocida: \(action)")
        }
    }

    // MARK: - Acciones

    private func list() async -> ToolResult {
        let goals = await otherModel.allGoals().filter { $0.status == .active || $0.status == .pendingConfirmation }
        guard !goals.isEmpty else { return ToolResult(content: "El dueño no tiene metas activas.") }
        var lines: [String] = []
        for goal in goals {
            var parts = ["- [\(goal.id)] \(goal.statement) (\(goal.source.rawValue), \(goal.desiredState.label))"]
            if goal.checkIn.isActive { parts.append("check-in \(goal.checkIn.phrase)") }
            let streak = await otherModel.streak(goalId: goal.id)
            if streak > 0 { parts.append("racha \(streak) días") }
            if let last = await otherModel.lastCheckIn(goalId: goal.id), let answer = last.answer {
                parts.append("último check-in: \(answer.rawValue)" + (last.note.isEmpty ? "" : " — \(last.note)"))
            }
            lines.append(parts.joined(separator: "; "))
        }
        return ToolResult(content: lines.joined(separator: "\n"))
    }

    private func declare(_ input: JSONValue) async -> ToolResult {
        let statement = (input["statement"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty else { return Self.error("falta 'statement'.") }
        var checkIn: CheckInCadence?
        if let raw = input["checkin"] {
            guard let parsed = Self.cadence(from: raw) else { return Self.error(Self.cadenceHelp) }
            checkIn = parsed
        }
        let predicate: ObservablePredicate
        if let raw = input["predicate"] {
            guard let parsed = Self.predicate(from: raw) else {
                return Self.error("'predicate' no es del vocabulario cerrado (ver descripción de la tool).")
            }
            predicate = parsed
        } else {
            predicate = .progressCheckIn(everyDays: Self.defaultEveryDays(checkIn?.cadence ?? .none))
        }
        let id = await otherModel.ingestStated(statement: statement, desiredState: predicate,
                                               evidence: "declarada en el chat")
        if let checkIn, checkIn.isActive { _ = await otherModel.setCheckIn(id: id, checkIn) }
        await onChange()
        let suffix = (checkIn?.isActive ?? false) ? " Te pregunto \(checkIn!.phrase)." : ""
        return ToolResult(content: "Meta registrada (id \(id)): \(statement).\(suffix)")
    }

    private func setCheckIn(_ input: JSONValue) async -> ToolResult {
        guard let goalId = input["goal_id"]?.stringValue else { return Self.error("falta 'goal_id'.") }
        guard let checkIn = Self.cadence(from: input) else { return Self.error(Self.cadenceHelp) }
        guard await otherModel.setCheckIn(id: goalId, checkIn) else { return Self.notFound }
        await onChange()
        return ToolResult(content: checkIn.isActive ? "Check-in fijado: \(checkIn.phrase)." : "Check-in quitado.")
    }

    private func clearCheckIn(_ input: JSONValue) async -> ToolResult {
        guard let goalId = input["goal_id"]?.stringValue else { return Self.error("falta 'goal_id'.") }
        guard await otherModel.clearCheckIn(id: goalId) else { return Self.notFound }
        await onChange()
        return ToolResult(content: "Check-in quitado.")
    }

    private func recordCheckIn(_ input: JSONValue) async -> ToolResult {
        guard let goalId = input["goal_id"]?.stringValue else { return Self.error("falta 'goal_id'.") }
        guard let answer = input["answer"]?.stringValue.flatMap(CheckInAnswer.init(rawValue:)) else {
            return Self.error("'answer' debe ser yes, partial, no o skipped.")
        }
        let note = input["note"]?.stringValue ?? ""
        guard await otherModel.recordCheckIn(goalId: goalId, answer: answer, note: note) != nil else {
            return Self.notFound
        }
        let streak = await otherModel.streak(goalId: goalId)
        return ToolResult(content: "Check-in anotado (\(answer.rawValue)). Racha: \(streak) días.")
    }

    private func markAchieved(_ input: JSONValue) async -> ToolResult {
        guard let goalId = input["goal_id"]?.stringValue else { return Self.error("falta 'goal_id'.") }
        guard await otherModel.goal(id: goalId) != nil else { return Self.notFound }
        await otherModel.markAchieved(id: goalId)
        await onChange()
        return ToolResult(content: "Meta marcada como lograda.")
    }

    // MARK: - Parseo

    static let cadenceHelp = "check-in inválido: cadence none|daily|weekdays|weekly, hour 0-23, minute 0-59, weekday 1-7."
    static let notFound = ToolResult(content: "Error: no existe una meta con ese goal_id.", isError: true)

    static func error(_ message: String) -> ToolResult {
        ToolResult(content: "Error: \(message)", isError: true)
    }

    /// {cadence, hour?, minute?, weekday?} → cadencia validada (default 20:00).
    static func cadence(from value: JSONValue) -> CheckInCadence? {
        guard let raw = value["cadence"]?.stringValue, let cadence = ProactiveCadence(rawValue: raw) else { return nil }
        let hour = int(value["hour"]) ?? CheckInCadence.defaultHour
        let minute = int(value["minute"]) ?? 0
        let weekday = int(value["weekday"])
        let checkIn = CheckInCadence(cadence: cadence, hour: hour, minute: minute,
                                     weekday: cadence == .weekly ? (weekday ?? 2) : nil)
        return checkIn.isValid ? checkIn : nil
    }

    static func predicate(from value: JSONValue) -> ObservablePredicate? {
        guard let data = try? JSONEncoder().encode(value),
              let dto = try? JSONDecoder().decode(PredicateDTO.self, from: data) else { return nil }
        return dto.toPredicate()
    }

    /// Sin predicado explícito: avanzar al menos una vez por periodo de check-in (+1 día de gracia).
    static func defaultEveryDays(_ cadence: ProactiveCadence) -> Int {
        switch cadence {
        case .daily, .weekdays: return 2
        case .weekly: return 8
        case .none: return 7
        }
    }

    static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let n)?: return n
        case .double(let d)?: return Int(d)
        case .string(let s)?: return Int(s)
        default: return nil
        }
    }
}
