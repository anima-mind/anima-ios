// AnimaRemindersTool.swift — tool `anima_reminders`: los recordatorios PERSONALES
// de Anima (su SQLite, los entrega ella y hace seguimiento en el chat). Distinta
// de `reminders` (app Recordatorios del iPhone) y `calendar` (agenda). Leer =
// aferente; crear/completar/cancelar/posponer = eferente (ask). Tras cada cambio
// el shell re-sincroniza las notificaciones locales (`onChange`).

import Foundation

public struct AnimaRemindersTool: SensorimotorTool {
    private let store: AnimaReminderStore
    private let timeZone: TimeZone
    private let onChange: @Sendable () async -> Void

    public init(store: AnimaReminderStore, timeZone: TimeZone = .current,
                onChange: @escaping @Sendable () async -> Void = {}) {
        self.store = store
        self.timeZone = timeZone
        self.onChange = onChange
    }

    private static let readOps: Set<String> = ["list"]
    private static let cadences = ProactiveCadence.allCases.map { JSONValue.string($0.rawValue) }

    public var spec: ToolSpec {
        .client(
            name: "anima_reminders",
            description: """
                Recordatorios PERSONALES de Anima: los guardas tú, los entregas tú misma \
                (notificación con tu nombre) y luego haces seguimiento en el chat. Úsala \
                por defecto cuando el dueño diga "recuérdame…". Para citas/eventos, \
                "agéndame", "ponlo en el calendario" o algo con lugar, asistentes o duración \
                usa `calendar`; si pide explícitamente sus recordatorios del iPhone o la app \
                Recordatorios usa `reminders`. Si es ambiguo y parece una cita, pregunta una \
                vez. Acciones: list, create {text, message, fire_at, repeat?, goal_id?}, complete {id}, \
                cancel {id}, snooze {id, minutes}. En create, `message` es OBLIGATORIO: lo que \
                le dirás al dueño cuando llegue la hora, en tu voz y en segunda persona, una \
                frase cálida y concreta (p.ej. "Oye, en media hora tienes la cita médica"); \
                jamás un título impersonal como "Avisar de la cita". fire_at en ISO 8601 (con offset; sin offset = hora local), resuelto \
                contra la línea "Ahora:" del contexto (p.ej. 2026-10-06T09:00:00-05:00). \
                goal_id liga el recordatorio a una meta (ver tool goals). Son tuyos y \
                reversibles desde la tab Recordatorios: llama la tool directo, sin pedir \
                permiso en el chat, y cuéntale al dueño qué quedó.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array(["list", "create", "complete", "cancel", "snooze"].map { .string($0) }),
                        "description": .string("Operación a realizar."),
                    ]),
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("Qué recordar, en palabras del dueño (para create)."),
                    ]),
                    "message": .object([
                        "type": .string("string"),
                        "description": .string("Obligatorio en create: lo que le dirás al dueño cuando llegue la hora, en tu voz y en segunda persona, 1 frase (p.ej. 'Oye, en media hora tienes la cita médica')."),
                    ]),
                    "fire_at": .object([
                        "type": .string("string"),
                        "description": .string("Cuándo, ISO 8601 con offset (para create)."),
                    ]),
                    "repeat": .object([
                        "type": .string("string"),
                        "enum": .array(Self.cadences),
                        "description": .string("Repetición (default none)."),
                    ]),
                    "goal_id": .object([
                        "type": .string("string"),
                        "description": .string("Meta a la que sirve (opcional)."),
                    ]),
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Id del recordatorio (complete/cancel/snooze)."),
                    ]),
                    "minutes": .object([
                        "type": .string("integer"),
                        "description": .string("Minutos a posponer (snooze)."),
                    ]),
                ]),
                "required": .array([.string("action")]),
                "additionalProperties": .bool(false),
            ]))
    }

    public func kind(for input: JSONValue) -> ToolKind {
        Self.readOps.contains(input["action"]?.stringValue ?? "") ? .afferent : .efferent
    }

    public func confirmationSummary(for input: JSONValue) -> String {
        let id = input["id"]?.stringValue ?? "?"
        switch input["action"]?.stringValue {
        case "create":
            let text = input["text"]?.stringValue ?? "(sin texto)"
            let when = input["fire_at"]?.stringValue.flatMap { Self.parseDate($0, timeZone: timeZone) }
                .map { Self.readable($0, timeZone: timeZone) } ?? input["fire_at"]?.stringValue ?? "?"
            let cadence = input["repeat"]?.stringValue.flatMap(ProactiveCadence.init(rawValue:))?.phrase
            let spoken = input["message"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            return "Recordarte '\(text)' el \(when)" + (cadence.map { " (\($0))" } ?? "")
                + (spoken.map { ". Te diré: «\($0)»" } ?? "")
        case "complete":
            return "Marcar como hecho el recordatorio \(id)"
        case "cancel":
            return "Cancelar el recordatorio \(id)"
        case "snooze":
            return "Posponer \(Self.minutes(input) ?? 0) min el recordatorio \(id)"
        default:
            return "anima_reminders: \(operation(for: input))"
        }
    }

    public func execute(_ input: JSONValue) async -> ToolResult {
        guard let action = input["action"]?.stringValue else {
            return ToolResult(content: "Error: falta 'action'.", isError: true)
        }
        do {
            switch action {
            case "list":
                return await list()
            case "create":
                return try await create(input)
            case "complete":
                let r = try await store.complete(id: try Self.require(input, "id"))
                await onChange()
                return ToolResult(content: "Recordatorio '\(r.text)' marcado como hecho.")
            case "cancel":
                let r = try await store.cancel(id: try Self.require(input, "id"))
                await onChange()
                return ToolResult(content: "Recordatorio '\(r.text)' cancelado.")
            case "snooze":
                guard let minutes = Self.minutes(input) else {
                    return ToolResult(content: "Error: falta 'minutes'.", isError: true)
                }
                let r = try await store.snooze(id: try Self.require(input, "id"), minutes: minutes)
                await onChange()
                return ToolResult(content: "Listo: te lo recuerdo el \(Self.readable(r.fireAt, timeZone: timeZone)) (id \(r.id)).")
            default:
                return ToolResult(content: "Acción de anima_reminders desconocida: \(action)", isError: true)
            }
        } catch let error as AnimaReminderError {
            return ToolResult(content: "Error: \(error.errorDescription ?? "\(error)").", isError: true)
        } catch let error as ToolInputError {
            return ToolResult(content: "Error: \(error.message)", isError: true)
        } catch {
            return ToolResult(content: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    private func list() async -> ToolResult {
        let upcoming = await store.list(.upcoming, limit: 50)
        let fired = await store.list(.fired, limit: 10)
        guard !upcoming.isEmpty || !fired.isEmpty else {
            return ToolResult(content: "No tienes recordatorios de Anima.")
        }
        var lines: [String] = []
        if !upcoming.isEmpty {
            lines.append("Programados:")
            lines += upcoming.map { line($0, when: $0.fireAt) }
        }
        if !fired.isEmpty {
            lines.append("Ya entregados (sin marcar hechos):")
            lines += fired.map { line($0, when: $0.firedAt ?? $0.fireAt) }
        }
        return ToolResult(content: lines.joined(separator: "\n"))
    }

    private func line(_ r: AnimaReminder, when: Date) -> String {
        let cadence = r.repeatCadence.phrase.map { ", \($0)" } ?? ""
        let goal = r.goalId.map { ", meta \($0)" } ?? ""
        return "- [\(r.id)] \(r.text) — \(Self.readable(when, timeZone: timeZone))\(cadence)\(goal)"
    }

    private func create(_ input: JSONValue) async throws -> ToolResult {
        let text = input["text"]?.stringValue ?? ""
        let raw = try Self.require(input, "fire_at")
        guard let fireAt = Self.parseDate(raw, timeZone: timeZone) else {
            throw ToolInputError(message: "'fire_at' debe ser fecha y hora ISO 8601 (p.ej. 2026-10-06T09:00:00-05:00).")
        }
        let cadence: ProactiveCadence
        if let rawCadence = input["repeat"]?.stringValue {
            guard let parsed = ProactiveCadence(rawValue: rawCadence) else {
                throw ToolInputError(message: "'repeat' debe ser none, daily, weekdays o weekly.")
            }
            cadence = parsed
        } else {
            cadence = .none
        }
        let goalId = input["goal_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let message = input["message"]?.stringValue
        let r = try await store.create(text: text, message: message, fireAt: fireAt, repeat: cadence, goalId: goalId)
        await onChange()
        let suffix = cadence.phrase.map { " (\($0))" } ?? ""
        return ToolResult(content: "Listo: te recuerdo '\(r.text)' el \(Self.readable(r.fireAt, timeZone: timeZone))\(suffix); te diré: «\(r.spokenMessage)». Id \(r.id).")
    }

    // MARK: - Helpers

    struct ToolInputError: Error { let message: String }

    static func require(_ input: JSONValue, _ key: String) throws -> String {
        guard let value = input[key]?.stringValue, !value.isEmpty else {
            throw ToolInputError(message: "falta '\(key)'.")
        }
        return value
    }

    static func minutes(_ input: JSONValue) -> Int? {
        if case .int(let n)? = input["minutes"] { return n }
        if case .double(let d)? = input["minutes"] { return Int(d) }
        return input["minutes"]?.stringValue.flatMap(Int.init)
    }

    /// ISO 8601 con o sin offset y fracción (mismo parser que calendar/reminders):
    /// sin offset = hora local de `timeZone`.
    static func parseDate(_ raw: String, timeZone: TimeZone = .current) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return AnimaDateText(calendar: calendar).parseISODateTime(raw)
    }

    /// "martes 6 de octubre a las 09:00" (es_CO, hora local).
    static func readable(_ date: Date, timeZone: TimeZone) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_CO")
        df.timeZone = timeZone
        df.dateFormat = "EEEE d 'de' MMMM 'a las' HH:mm"
        return df.string(from: date)
    }
}
