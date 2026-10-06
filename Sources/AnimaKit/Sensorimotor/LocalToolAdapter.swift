// LocalToolAdapter.swift — las tools que ve el modelo de Apple (~3B, ventana de
// 4096). Medido en el modelo real (2026-10-06): con tools multiplexadas por
// `action` y 8 parámetros opcionales logró 0 de 4 acciones. Aquí cada tool es
// UNA intención, con 0-3 parámetros obligatorios y una línea con un ejemplo
// literal. El adapter traduce cada llamada a la tool real del registro
// (`anima_reminders`, `goals`, `calendar`, `notes`) y la ejecución sigue por el
// mismo Sensorimotor (permisos, confirmación, timeout): solo cambia la forma.
//
// Fechas: el 3B no sabe de zonas. `when`/`start`/`end` se leen SIEMPRE como
// hora de pared local: si llega `Z` u offset, se ignora la zona.

import Foundation

public enum LocalToolAdapter {

    /// Una tool local: su spec (lo que viaja al modelo) y la tool real que la ejecuta.
    public struct LocalTool: Sendable {
        public let name: String
        public let realTool: String
        /// La `action` de la tool real (el verbo del aviso de fallo).
        public let realAction: String
        public let spec: ToolSpec
        /// El ejemplo literal de la descripción (vuelve en el error accionable).
        public let example: String
    }

    /// Resultado de traducir una llamada del modelo local.
    public enum Resolution: Sendable, Equatable {
        /// La llamada real que ejecuta el Sensorimotor.
        case real(name: String, input: JSONValue)
        /// Parámetros que no se pudieron reparar: error corto y accionable.
        case invalid(tool: String, message: String)
    }

    public static let datePattern = #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}"#

    public static let tools: [LocalTool] = [
        LocalTool(
            name: "remind_me", realTool: "anima_reminders", realAction: "create",
            spec: spec("remind_me",
                       "Crea un recordatorio a una hora. Ej: {text:'tomar la pastilla', when:'2026-10-07 08:00', repeat:'none'}",
                       [("text", .text), ("when", .date), ("repeat", .text)]),
            example: "{text:'tomar la pastilla', when:'2026-10-07 08:00', repeat:'none'}"),
        LocalTool(
            name: "list_reminders", realTool: "anima_reminders", realAction: "list",
            spec: spec("list_reminders", "Lista los recordatorios programados.", []),
            example: "{}"),
        LocalTool(
            name: "declare_goal", realTool: "goals", realAction: "declare",
            spec: spec("declare_goal",
                       "Registra una meta; checkin none|daily|weekdays|weekly. Ej: {statement:'leer 10 libros', checkin:'weekly', hour:20}",
                       [("statement", .text), ("checkin", .text), ("hour", .hour)]),
            example: "{statement:'leer 10 libros', checkin:'weekly', hour:20}"),
        LocalTool(
            name: "list_goals", realTool: "goals", realAction: "list",
            spec: spec("list_goals", "Lista las metas del dueño.", []),
            example: "{}"),
        LocalTool(
            name: "add_calendar_event", realTool: "calendar", realAction: "create",
            spec: spec("add_calendar_event",
                       "Agéndame: pone una cita o reunión en el calendario. Ej: {title:'almuerzo con Ana', start:'2026-10-08 13:00', end:'2026-10-08 14:00'}",
                       [("title", .text), ("start", .date), ("end", .date)]),
            example: "{title:'almuerzo con Ana', start:'2026-10-08 13:00', end:'2026-10-08 14:00'}"),
        LocalTool(
            name: "list_events", realTool: "calendar", realAction: "list",
            spec: spec("list_events", "Lee las citas del calendario de los próximos días. Ej: {days:7}",
                       [("days", .days)]),
            example: "{days:7}"),
        LocalTool(
            name: "write_note", realTool: "notes", realAction: "append",
            spec: spec("write_note", "Guarda una nota. Ej: {name:'libros', content:'leer Rayuela'}",
                       [("name", .text), ("content", .text)]),
            example: "{name:'libros', content:'leer Rayuela'}"),
        LocalTool(
            name: "read_note", realTool: "notes", realAction: "read",
            spec: spec("read_note", "Lee una nota. Ej: {name:'libros'}", [("name", .text)]),
            example: "{name:'libros'}"),
    ]

    /// "crear el recordatorio": la intención de una tool local.
    public static func verb(local name: String) -> String {
        guard let tool = byName[name] else { return "usar \(name)" }
        return ToolFailureNotice.verb(tool: tool.realTool, input: .object(["action": .string(tool.realAction)]))
    }

    /// Las que solo leen: tras ellas el modelo responde con lo leído.
    public static let readOnlyTools: Set<String> = ["list_reminders", "list_goals", "list_events", "read_note"]

    static let byName: [String: LocalTool] = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

    /// Las tools reales que tienen forma local.
    public static var realTools: Set<String> { Set(tools.map(\.realTool)) }

    public static func tool(named name: String) -> LocalTool? { byName[name] }

    /// Las specs locales para las tools reales disponibles (orden estable).
    /// Idempotente: acepta specs reales o ya locales.
    public static func specs(for available: [ToolSpec]) -> [ToolSpec] {
        var real = Set<String>()
        for spec in available {
            guard case .client(let name, _, _) = spec else { continue }
            if let local = byName[name] { real.insert(local.realTool) } else { real.insert(name) }
        }
        return tools.filter { real.contains($0.realTool) }.map(\.spec)
    }

    // MARK: - Traducción

    /// Traduce una llamada del modelo local a la tool real. `now` resuelve
    /// "hoy/mañana/jueves" cuando el modelo no manda la fecha numérica.
    /// `ownerText` (el turno del dueño) repara la hora y el día cuando el dueño
    /// los dijo sin ambigüedad ("el jueves a las 3 pm"): el 3B se equivoca
    /// convirtiendo "3 pm" o contando días; lo dicho por el dueño gana.
    public static func resolve(name: String, input: JSONValue, now: Date, ownerText: String = "",
                               calendar: Calendar = .current) -> Resolution {
        guard let tool = byName[name] else {
            return .invalid(tool: name, message: "No existe la herramienta '\(name)'. Usa: "
                            + tools.map(\.name).joined(separator: ", ") + ".")
        }
        let args = Args(input)
        let when = LocalWhen(now: now, calendar: calendar, ownerText: ownerText)
        func invalid(_ message: String) -> Resolution { .invalid(tool: tool.realTool, message: message) }

        // Medido: las tools sin parámetros atraen al 3B ("recuérdame…" →
        // list_reminders en ~1 de 8). Si el dueño pidió crear, no se consulta:
        // error guiado hacia la tool correcta (un reintento).
        let intended = intended(name: name, ownerText: ownerText)
        if intended != name, let target = byName[intended] {
            return .invalid(tool: target.realTool, message: "El dueño pidió crear algo, no consultar: usa \(intended).")
        }

        switch name {
        case "remind_me":
            guard let text = args.text("text") else { return invalid(missing("text", "qué recordar")) }
            guard let parsedWhen = args.raw("when").flatMap({ when.parse($0) }) else {
                return invalid(missing("when", "formato 'YYYY-MM-DD HH:MM', hora local"))
            }
            guard let modelCadence = args.cadence("repeat") else { return invalid(cadenceHelp("repeat")) }
            // La repetición que dijo el dueño gana; si fijó un único momento
            // ("mañana a las 9") no se repite (medido: el 3B ponía daily); si no
            // dijo nada, la del modelo.
            let cadence = when.ownerCadence ?? (when.ownerSaysOnce ? .none : modelCadence)
            return reminder(text: text, at: parsedWhen, cadence: cadence, now: now, when: when, calendar: calendar)

        case "list_reminders", "list_goals":
            return .real(name: tool.realTool, input: .object(["action": .string("list")]))

        case "declare_goal":
            guard let statement = args.text("statement") else {
                return invalid(missing("statement", "la meta en palabras del dueño"))
            }
            guard let modelCadence = args.cadence("checkin") else { return invalid(cadenceHelp("checkin")) }
            let cadence = when.ownerCadence ?? modelCadence
            // "recuérdame todos los días a las 8 tomar agua" es un recordatorio,
            // no una meta (regla de la app: "recuérdame…" ⇒ recordatorio).
            if when.ownerAsksForAReminder {
                let clock = when.ownerExplicitTime ?? (args.hour("hour").map { ($0, 0) } ?? (CheckInCadence.defaultHour, 0))
                let day = when.ownerDay ?? calendar.startOfDay(for: now)
                guard let at = calendar.date(bySettingHour: clock.0, minute: clock.1, second: 0, of: day) else {
                    return invalid(missing("when", "formato 'YYYY-MM-DD HH:MM', hora local"))
                }
                guard let reminders = byName["remind_me"] else { return invalid("Sin recordatorios.") }
                let rerouted = reminder(text: statement, at: at, cadence: cadence, now: now, when: when,
                                        calendar: calendar, rollPastOnce: true)
                if case .real(_, let input) = rerouted { return .real(name: reminders.realTool, input: input) }
                return rerouted
            }
            var object: [String: JSONValue] = ["action": .string("declare"), "statement": .string(statement)]
            if cadence != .none {
                guard var hour = args.hour("hour") else { return invalid("`hour` debe ser una hora de 0 a 23.") }
                // Sin hora dicha por el dueño, la del modelo es invento: la default.
                if !when.ownerMentionsTime { hour = CheckInCadence.defaultHour }
                if let owner = when.ownerExplicitTime { hour = owner.hour }
                var checkin: [String: JSONValue] = ["cadence": .string(cadence.rawValue), "hour": .int(hour)]
                // "cada domingo": sin el día, GoalsTool pondría lunes y el texto mentiría.
                if cadence == .weekly, let weekday = when.ownerWeekday { checkin["weekday"] = .int(weekday) }
                object["checkin"] = .object(checkin)
            }
            return .real(name: tool.realTool, input: .object(object))

        case "list_events":
            let days = args.raw("days").flatMap { Int($0.prefix { $0.isNumber }) }.map { min(max($0, 1), 30) } ?? 7
            return .real(name: tool.realTool, input: .object(["action": .string("list"), "days_ahead": .int(days)]))

        case "add_calendar_event":
            guard let title = args.text("title") else { return invalid(missing("title", "el título de la cita")) }
            guard let start = args.raw("start").flatMap({ when.parse($0) }) else {
                return invalid(missing("start", "formato 'YYYY-MM-DD HH:MM', hora local"))
            }
            let end = when.eventEnd(start: start, modelEnd: args.raw("end").flatMap { when.parse($0, repair: false) })
            return .real(name: tool.realTool, input: .object([
                "action": .string("create"), "title": .string(title),
                "start": .string(when.isoLocal(start)), "end": .string(when.isoLocal(end)),
            ]))

        case "write_note":
            // Medido: a veces copia el nombre como contenido ({name:'compras',
            // content:'compras'}): lo dictado por el dueño gana.
            var content = args.text("content")
            if content == nil || content?.lowercased() == args.text("name")?.lowercased() {
                content = dictatedNote(ownerText) ?? content
            }
            guard var content else { return invalid(missing("content", "el texto de la nota")) }
            var noteName = args.text("name") ?? defaultNoteName(content)
            // Medido: a veces invierte los campos ({name:'la clave del wifi es casa123',
            // content:'wifi'}): el texto largo es el contenido y el nombre, 1-3 palabras.
            if LocalWhen.words(noteName).count > 3, LocalWhen.words(content).count <= 3, noteName.count > content.count {
                swap(&noteName, &content)
            }
            // append: nunca pisa una nota existente (crear también, si no existe).
            return .real(name: tool.realTool, input: .object([
                "action": .string("append"), "name": .string(noteName), "content": .string(content),
            ]))

        case "read_note":
            guard let noteName = args.text("name") else {
                return .real(name: tool.realTool, input: .object(["action": .string("list")]))
            }
            return .real(name: tool.realTool, input: .object(["action": .string("read"), "name": .string(noteName)]))

        default:
            return invalid("No existe la herramienta '\(name)'.")
        }
    }

    /// anima_reminders.create; una hora ya pasada se corre a la siguiente
    /// ocurrencia si se repite (o, con `rollPastOnce`, al día siguiente).
    static func reminder(text: String, at date: Date, cadence: ProactiveCadence, now: Date, when: LocalWhen,
                         calendar: Calendar, rollPastOnce: Bool = false) -> Resolution {
        var fireAt = date
        while cadence != .none || rollPastOnce, fireAt <= now,
              let next = calendar.date(byAdding: .day, value: cadence == .weekly ? 7 : 1, to: fireAt) {
            fireAt = next
        }
        return .real(name: "anima_reminders", input: .object([
            "action": .string("create"), "text": .string(text), "message": .string(spokenFallback(text)),
            "fire_at": .string(when.isoLocal(fireAt)), "repeat": .string(cadence.rawValue),
        ]))
    }

    /// El resultado que lee el modelo local: si el de la tool real es parco
    /// ("Anexado a 'compras'."), lo dice completo para que lo cuente bien.
    public static func present(_ result: ToolResult, local name: String, input: JSONValue,
                               dates: AnimaDateText = AnimaDateText()) -> ToolResult {
        guard !result.isError else { return result }
        var presented = result
        switch name {
        case "write_note":
            guard let note = input["name"]?.stringValue, let content = input["content"]?.stringValue else { return result }
            presented.content = "Anotado en tu nota '\(note)': \(content)."
        case "add_calendar_event":
            guard let title = input["title"]?.stringValue, let start = input["start"]?.stringValue else { return result }
            let line = "Evento '\(title)' agendado el \(dates.readableISO(start))"
            presented.content = line.hasSuffix(".") ? line : line + "."
        case "list_goals":
            presented.content = readableGoals(result.content)
        default:
            return result
        }
        return presented
    }

    /// "- [G1] leer (stated, reportar avance cada 8 días); check-in cada domingo a
    /// las 20:00; racha 2 días" ⇒ "- leer — te pregunto cada domingo a las 20:00; racha 2 días".
    static func readableGoals(_ text: String) -> String {
        if text.hasPrefix("El dueño no tiene") { return "No tienes metas activas." }
        return text.split(separator: "\n").map { line -> String in
            guard line.hasPrefix("- ") else { return String(line) }
            var parts = line.dropFirst(2).components(separatedBy: "; ")
            var head = parts.removeFirst().replacing(/^\[[^\]]*\]\s*/, with: "")
            if let paren = head.range(of: " (", options: .backwards), head.hasSuffix(")") {
                head = String(head[..<paren.lowerBound])
            }
            let rest = parts.map { $0.hasPrefix("check-in ") ? "te pregunto " + $0.dropFirst(9) : $0 }
            return "- " + ([head] + rest).joined(separator: " — ")
        }.joined(separator: "\n")
    }

    /// La tool que corresponde a lo que pidió el dueño cuando el modelo eligió
    /// una de consulta para un pedido de creación; si no, `name`.
    public static func intended(name: String, ownerText: String) -> String {
        guard readOnlyTools.contains(name) else { return name }
        let raw = ownerText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = LocalWhen.fold(raw)
        // Una consulta nunca se redirige, lleve o no "?" ("quiero ver mis metas",
        // "dime qué tengo", "cuáles son mis recordatorios").
        let asks = ["qué ", "cuál", "cómo", "cuándo", "?", "¿"].contains(where: raw.contains)
            || ["que ", "cuales ", "cual ", "muestrame", "dime", "lista", "lee ", "leeme"].contains(where: owner.hasPrefix)
        guard !owner.isEmpty, !asks else { return name }
        let targets: [(String, [String])] = [
            ("remind_me", ["recuerdame", "recordarme", "recuerdeme"]),
            ("add_calendar_event", ["agendame", "agenda una", "agenda la", "agenda el"]),
            ("write_note", ["anota", "apunta", "toma nota"]),
            ("declare_goal", ["mi meta", "mi objetivo", "me propongo"]),
        ]
        if let target = targets.first(where: { $0.1.contains(where: owner.contains) }) { return target.0 }
        // "quiero" solo es meta con un verbo de meta detrás ("quiero bajar 5 kilos").
        let consults = ["ver ", "saber", "revisar", "consultar", "mirar", "mis "].contains(where: owner.contains)
        if !consults, let match = owner.firstMatch(of: /\bquiero (\w+)/), Self.goalVerbs.contains(String(match.1)) {
            return "declare_goal"
        }
        return name
    }

    static let goalVerbs: Set<String> = [
        "bajar", "subir", "leer", "correr", "aprender", "ahorrar", "dejar", "empezar", "comenzar", "terminar",
        "hacer", "ir", "dormir", "comer", "tomar", "estudiar", "escribir", "meditar", "caminar", "nadar",
        "entrenar", "practicar", "llegar", "lograr", "mejorar", "reducir", "aumentar", "ganar", "perder",
    ]

    /// ¿El error de la tool real es de datos (reintentar con otros sirve) y no
    /// del mundo (permiso, store)? "la fecha ya pasó", "falta 'x'", "debe ser…".
    public static func isParameterError(_ content: String) -> Bool {
        let folded = LocalWhen.fold(content)
        return ["falta ", "debe ser", "ya paso", "invalido", "no existe una meta", "esta vacio", "no se entiende"]
            .contains(where: folded.contains)
    }

    /// El error accionable que vuelve al modelo: qué falló + el ejemplo literal.
    public static func retryHint(tool name: String, message: String) -> String {
        guard let example = byName[name]?.example else { return message }
        return "\(message) Corrige y llama \(name) otra vez. Ej: \(example)"
    }

    static func missing(_ field: String, _ hint: String) -> String {
        "Falta `\(field)` o no se entiende: \(hint)."
    }

    static func cadenceHelp(_ field: String) -> String {
        "`\(field)` debe ser none, daily, weekdays o weekly."
    }

    /// Lo que ella dice al entregarlo cuando el modelo local no lo redactó.
    public static func spokenFallback(_ text: String) -> String {
        "Oye, acuérdate de \(text)."
    }

    /// "anota: comprar leche y pan" → "comprar leche y pan" (nil si el dueño no dictó).
    static func dictatedNote(_ ownerText: String) -> String? {
        let pattern = /^\s*(?:por favor,?\s*)?(?:an[oó]ta(?:me)?|apunta(?:me)?|toma nota(?: de)?|guarda(?: una nota)?)(?:\s+que)?\s*:?\s*(.+)$/
            .ignoresCase()
        guard let match = ownerText.firstMatch(of: pattern) else { return nil }
        let text = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return text.isEmpty ? nil : text
    }

    /// Nombre de nota por defecto: las primeras palabras del contenido.
    static func defaultNoteName(_ content: String) -> String {
        let words = content.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.prefix(3).joined(separator: "-").isEmpty ? "nota" : words.prefix(3).joined(separator: "-")
    }

    // MARK: - Specs

    enum Field: Sendable {
        case text
        case date
        case hour
        case days
        case choice([String])

        var schema: JSONValue {
            switch self {
            case .text: return .object(["type": .string("string")])
            case .date: return .object(["type": .string("string"), "pattern": .string(LocalToolAdapter.datePattern)])
            case .hour: return .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(23)])
            case .days: return .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(30)])
            case .choice(let values): return .object(["type": .string("string"), "enum": .array(values.map { .string($0) })])
            }
        }
    }

    static func spec(_ name: String, _ description: String, _ fields: [(String, Field)]) -> ToolSpec {
        var properties: [String: JSONValue] = [:]
        for (key, field) in fields { properties[key] = field.schema }
        return .client(name: name, description: description, inputSchema: .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(fields.map { .string($0.0) }),
            "additionalProperties": .bool(false),
        ]))
    }
}

// MARK: - Argumentos tolerantes

/// Lectura tolerante de los argumentos del modelo local: trim, minúsculas en
/// vocabularios, sinónimos obvios y números que llegan como texto.
struct Args {
    let input: JSONValue

    init(_ input: JSONValue) { self.input = input }

    func raw(_ key: String) -> String? {
        switch input[key] {
        case .string(let s)?: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .int(let n)?: return String(n)
        case .double(let d)?: return String(d)
        default: return nil
        }
    }

    func text(_ key: String) -> String? {
        guard let value = raw(key), !value.isEmpty else { return nil }
        return value
    }

    /// Ausente o vacío ⇒ none (default seguro). Desconocido ⇒ nil (error).
    func cadence(_ key: String) -> ProactiveCadence? {
        guard let value = raw(key)?.lowercased(), !value.isEmpty else { return ProactiveCadence.none }
        return Self.cadenceSynonyms[value.folding(options: .diacriticInsensitive, locale: nil)]
    }

    static let cadenceSynonyms: [String: ProactiveCadence] = [
        "none": .none, "no": .none, "ninguno": .none, "ninguna": .none, "nunca": .none, "once": .none,
        "una vez": .none, "null": .none,
        "daily": .daily, "diario": .daily, "diaria": .daily, "cada dia": .daily, "todos los dias": .daily,
        "day": .daily, "everyday": .daily,
        "weekdays": .weekdays, "weekday": .weekdays, "entre semana": .weekdays, "dias habiles": .weekdays,
        "laborables": .weekdays,
        "weekly": .weekly, "semanal": .weekly, "cada semana": .weekly, "week": .weekly, "semanalmente": .weekly,
    ]

    /// 0-23; ausente ⇒ la hora default del check-in; "8 pm"/"20:00" también.
    func hour(_ key: String) -> Int? {
        guard let value = raw(key)?.lowercased(), !value.isEmpty else { return CheckInCadence.defaultHour }
        let digits = value.prefix { $0.isNumber }
        guard var hour = Int(digits) else { return nil }
        if value.contains("p") && hour < 12 { hour += 12 }
        return (0...23).contains(hour) ? hour : nil
    }
}

// MARK: - Fechas en hora de pared

/// `when`/`start` del modelo local → fecha en hora LOCAL. Acepta
/// 'YYYY-MM-DD HH:MM' (con T, segundos, Z u offset: la zona se ignora) y, si el
/// modelo manda palabras, "hoy|mañana|pasado mañana|<día> [a las] 9[:30] [am|pm]".
///
/// `ownerText` repara lo que el dueño dijo sin ambigüedad, en este orden: "en N
/// horas/minutos" (relativo al reloj), fecha explícita ("15 de octubre",
/// "15/10"), "hoy", "pasado mañana", "mañana" y por último el día de la semana;
/// la hora solo si trae am/pm, "de la tarde/noche/mañana" o formato 24 h. Solo
/// cuenta la parte que agenda ("… a las 6 de la tarde | que mañana es el examen").
struct LocalWhen {
    let now: Date
    let calendar: Calendar
    var ownerText: String = ""

    /// `repair: false` para el fin de un evento (ver `eventEnd`).
    func parse(_ raw: String, repair: Bool = true) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let parsed = absolute(text) ?? relative(text) else { return nil }
        return repair ? repaired(parsed) : parsed
    }

    /// Lo que el dueño dijo sin ambigüedad pisa lo que calculó el modelo.
    func repaired(_ date: Date) -> Date {
        let owner = scheduleText
        guard !owner.isEmpty else { return date }
        if let offset = offset(owner) { return now.addingTimeInterval(offset) }
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        if let day = day(owner) {
            let d = calendar.dateComponents([.year, .month, .day], from: day)
            parts.year = d.year; parts.month = d.month; parts.day = d.day
        }
        if let clock = explicitTimes(owner).first {
            parts.hour = clock.hour; parts.minute = clock.minute
        }
        return calendar.date(from: parts) ?? date
    }

    /// Fin de un evento: "de 9 am a 11 am" ⇒ la última hora explícita del
    /// dueño; si no, el fin del modelo cuando es posterior al inicio; si no, 1 h.
    func eventEnd(start: Date, modelEnd: Date?) -> Date {
        let times = explicitTimes(scheduleText)
        if times.count >= 2, let last = times.last,
           let end = calendar.date(bySettingHour: last.hour, minute: last.minute, second: 0, of: start), end > start {
            return end
        }
        if let modelEnd, modelEnd > start, modelEnd.timeIntervalSince(start) <= 12 * 3600 { return modelEnd }
        return start.addingTimeInterval(3600)
    }

    // MARK: Lo que dijo el dueño

    /// La parte del turno que agenda: lo dictado tras " que " no fija el día
    /// ("recuérdame hoy a las 6 que mañana es el examen" ⇒ hoy), salvo que
    /// antes no haya nada de fecha u hora.
    var scheduleText: String {
        let owner = Self.fold(ownerText)
        guard let cut = owner.range(of: " que ") else { return owner }
        let head = String(owner[..<cut.lowerBound])
        let says = day(head) != nil || offset(head) != nil || !times(head).isEmpty
        return says ? head : owner
    }

    /// La repetición que dijo el dueño, o nil si no dijo ninguna.
    var ownerCadence: ProactiveCadence? {
        let owner = Self.fold(ownerText)
        guard !owner.isEmpty else { return nil }
        if ["entre semana", "de lunes a viernes", "dias habiles", "dias laborales", "dias laborables"]
            .contains(where: owner.contains) { return .weekdays }
        if ["todos los dias", "cada dia", "diario", "diariamente", "a diario", "cada manana", "cada noche",
            "todas las mananas", "todas las noches"].contains(where: owner.contains) { return .daily }
        if ["cada semana", "semanal", "todas las semanas"].contains(where: owner.contains) || ownerWeekday != nil {
            return .weekly
        }
        return nil
    }

    /// "cada domingo", "todos los lunes", "los sábados" ⇒ 1=domingo … 7=sábado.
    var ownerWeekday: Int? {
        let words = Self.words(Self.fold(ownerText))
        for (index, word) in words.enumerated() where index > 0 {
            guard let weekday = Self.weekday(word) else { continue }
            let previous = words[index - 1]
            let plural = word == "sabados" || word == "domingos"
            if previous == "cada" || previous == "los" || plural { return weekday }
        }
        return nil
    }

    /// El dueño fijó un único momento (hoy, mañana, una fecha, "en 2 horas",
    /// "el jueves"): sin palabras de repetición, no se repite.
    var ownerSaysOnce: Bool {
        let owner = scheduleText
        return ownerCadence == nil && (day(owner) != nil || offset(owner) != nil)
    }

    /// "recuérdame…" sin hablar de una meta.
    var ownerAsksForAReminder: Bool {
        let owner = Self.fold(ownerText)
        return ["recuerdame", "recordarme", "recuerdeme"].contains(where: owner.contains) && !owner.contains("meta")
    }

    var ownerMentionsTime: Bool { times(scheduleText).contains { $0.explicit || $0.afterLas } }
    var ownerExplicitTime: (hour: Int, minute: Int)? { explicitTimes(scheduleText).first }
    var ownerDay: Date? { day(scheduleText) }

    static func fold(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
    }

    static func words(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    }

    // MARK: Piezas

    private func absolute(_ text: String) -> Date? {
        let regex = /^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ t]+(\d{1,2}):(\d{2}))?/
        guard let match = text.firstMatch(of: regex) else { return nil }
        guard let hour = match.4.flatMap({ Int($0) }), let minute = match.5.flatMap({ Int($0) }) else {
            return nil
        }
        return make(year: Int(match.1), month: Int(match.2), day: Int(match.3), hour: hour, minute: minute)
    }

    private func relative(_ text: String) -> Date? {
        let folded = Self.fold(text)
        if let offset = offset(folded) { return now.addingTimeInterval(offset) }
        guard let clock = times(folded).first?.clock, let day = day(folded) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return make(year: parts.year, month: parts.month, day: parts.day, hour: clock.hour, minute: clock.minute)
    }

    /// "en 2 horas", "en 30 minutos", "en una hora", "en media hora" ⇒ segundos.
    func offset(_ folded: String) -> TimeInterval? {
        let regex = /\ben (\d{1,3}|un|una|media) (hora|horas|minuto|minutos|min)\b/
        guard let match = folded.firstMatch(of: regex) else { return nil }
        let amount: Double
        switch match.1 {
        case "un", "una": amount = 1
        case "media": amount = 0.5
        default: amount = Double(match.1) ?? 0
        }
        guard amount > 0 else { return nil }
        return match.2.hasPrefix("hora") ? amount * 3600 : amount * 60
    }

    static let months = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
                         "septiembre", "octubre", "noviembre", "diciembre"]

    /// "15 de octubre [de 2027]" o "15/10[/2027]"; sin año ⇒ la próxima vez que llega.
    func explicitDate(_ folded: String) -> Date? {
        var day: Int?, month: Int?, year: Int?
        if let m = folded.firstMatch(of: /\b(\d{1,2}) de ([a-z]+)(?: de (\d{4}))?/),
           let index = Self.months.firstIndex(of: String(m.2).replacingOccurrences(of: "setiembre", with: "septiembre")) {
            day = Int(m.1); month = index + 1; year = m.3.flatMap { Int($0) }
        } else if let m = folded.firstMatch(of: /\b(\d{1,2})\/(\d{1,2})(?:\/(\d{2,4}))?\b/) {
            day = Int(m.1); month = Int(m.2)
            year = m.3.flatMap { Int($0) }.map { $0 < 100 ? 2000 + $0 : $0 }
        }
        guard let day, let month else { return nil }
        let today = calendar.startOfDay(for: now)
        let thisYear = calendar.component(.year, from: today)
        guard let date = make(year: year ?? thisYear, month: month, day: day, hour: 0, minute: 0) else { return nil }
        if year == nil, date < today { return make(year: thisYear + 1, month: month, day: day, hour: 0, minute: 0) }
        return date
    }

    /// El día que nombra el texto (ya plegado), o nil. La fecha explícita gana
    /// al día de la semana; "hoy" gana a "mañana"; "de/por la mañana" es la
    /// franja, no el día siguiente.
    func day(_ folded: String) -> Date? {
        if let explicit = explicitDate(folded) { return explicit }
        let text = folded.replacingOccurrences(of: "de la manana", with: " ")
            .replacingOccurrences(of: "por la manana", with: " ")
        let words = Self.words(text)
        let today = calendar.startOfDay(for: now)
        func has(_ word: String) -> Bool { words.contains(word) }
        if has("hoy") { return today }
        if text.contains("pasado manana") { return calendar.date(byAdding: .day, value: 2, to: today) }
        if has("manana") { return calendar.date(byAdding: .day, value: 1, to: today) }
        guard let weekday = words.lazy.compactMap(Self.weekday).first else { return nil }
        let current = calendar.component(.weekday, from: today)
        var ahead = (weekday - current + 7) % 7
        if ahead == 0 { ahead = 7 }
        return calendar.date(byAdding: .day, value: ahead, to: today)
    }

    static let weekdays = ["domingo", "lunes", "martes", "miercoles", "jueves", "viernes", "sabado"]

    /// "lunes" / "sabados" ⇒ 1=domingo … 7=sábado.
    static func weekday(_ word: String) -> Int? {
        for (index, name) in weekdays.enumerated() where word == name || word == name + "s" { return index + 1 }
        return nil
    }

    struct TimeMention {
        var clock: (hour: Int, minute: Int)
        var explicit: Bool
        var afterLas: Bool
    }

    /// Las horas que nombra el texto, en orden. Explícita = am/pm, "de la
    /// tarde/noche/mañana", o 13-23 con minutos o tras "a las" (no "el 20 de octubre").
    func times(_ text: String) -> [TimeMention] {
        let regex = /(\d{1,2})(?::(\d{2}))?\s*(a\.?\s?m\.?|p\.?\s?m\.?)?(?!\s*de (?:enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre))(?!\s*\/)(?!\s*(?:hora|horas|minuto|minutos|min)\b)/
        var out: [TimeMention] = []
        for match in text.matches(of: regex) {
            let before = text[..<match.range.lowerBound]
            if before.hasSuffix("/") || before.hasSuffix("en ") { continue }
            guard var hour = Int(match.1) else { continue }
            let minute = match.2.flatMap { Int($0) } ?? 0
            let raw = hour
            let afterLas = before.hasSuffix("las ") || before.hasSuffix("la ")
            var explicit = false
            if let meridiem = match.3 {
                explicit = true
                if meridiem.hasPrefix("p") && hour < 12 { hour += 12 }
                if meridiem.hasPrefix("a") && hour == 12 { hour = 0 }
            } else if text.contains("de la tarde") || text.contains("de la noche"), hour < 12 {
                explicit = true
                hour += 12
            } else if text.contains("de la manana") {
                explicit = true
            } else if raw >= 13, match.2 != nil || afterLas {
                explicit = true
            }
            guard (0...23).contains(hour), (0...59).contains(minute) else { continue }
            out.append(TimeMention(clock: (hour, minute), explicit: explicit, afterLas: afterLas || match.2 != nil))
        }
        return out
    }

    /// Las horas explícitas, en el orden en que el dueño las dijo.
    func explicitTimes(_ text: String) -> [(hour: Int, minute: Int)] {
        times(text).filter(\.explicit).map(\.clock)
    }

    private func make(year: Int?, month: Int?, day: Int?, hour: Int, minute: Int) -> Date? {
        guard let year, let month, let day, (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day else { return nil }
        return date
    }

    /// 'yyyy-MM-ddTHH:mm:00' SIN offset: las tools reales lo leen como hora local.
    func isoLocal(_ date: Date) -> String {
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:00", p.year ?? 0, p.month ?? 0, p.day ?? 0,
                      p.hour ?? 0, p.minute ?? 0)
    }
}
