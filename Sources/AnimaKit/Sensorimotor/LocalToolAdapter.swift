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
    /// Listados que se entregan tal cual (sin que el 3B los resuma).
    public static let listTools: Set<String> = ["list_reminders", "list_goals", "list_events"]

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
            guard let modelText = args.text("text") else { return invalid(missing("text", "qué recordar")) }
            let text = reminderText(model: modelText, ownerText: ownerText)
            guard let parsedWhen = args.raw("when").flatMap({ when.parse($0) }) else {
                return invalid(missing("when", "formato 'YYYY-MM-DD HH:MM', hora local"))
            }
            // Una repetición no soportada (del dueño o del modelo: "monthly") no es
            // un error: se ignora la del modelo antes de validarla.
            let modelCadence = when.unsupportedCadence != nil ? .none : (args.cadence("repeat") ?? .none)
            // La repetición que dijo el dueño gana; si fijó un único momento
            // ("mañana a las 9") no se repite (medido: el 3B ponía daily); si no
            // dijo nada, la del modelo.
            // Una repetición que la app no sabe hacer ("cada 15 días", "cada mes")
            // nunca se degrada a diario/semanal: una vez, en la próxima fecha.
            if let unsupported = when.unsupportedCadence {
                return reminder(text: text, at: when.firstOccurrence(of: unsupported, modelDate: parsedWhen),
                                cadence: .none, now: now, when: when, calendar: calendar, rollPastOnce: true)
            }
            let cadence = when.ownerCadence ?? (when.ownerSaysOnce ? .none : modelCadence)
            // "hoy a las 12" cuando ya pasó: mañana a la misma hora (y se dice), no un error.
            let today = when.ownerDay.map { calendar.isDate($0, inSameDayAs: now) } ?? true
            return reminder(text: text, at: when.withPlausibleHour(parsedWhen), cadence: cadence, now: now, when: when,
                            calendar: calendar, rollPastOnce: cadence == .none && today && when.offsetMinutes == nil)

        case "list_reminders", "list_goals":
            return .real(name: tool.realTool, input: .object(["action": .string("list")]))

        case "declare_goal":
            guard let statement = args.text("statement") else {
                return invalid(missing("statement", "la meta en palabras del dueño"))
            }
            let modelCadence = when.unsupportedCadence != nil ? .none : (args.cadence("checkin") ?? .none)
            let cadence = when.ownerCadence ?? modelCadence
            // "recuérdame todos los días a las 8 tomar agua" es un recordatorio,
            // no una meta (regla de la app: "recuérdame…" ⇒ recordatorio).
            if when.ownerAsksForAReminder {
                let statement = reminderText(model: statement, ownerText: ownerText)
                let cadence = when.ownerCadence ?? (when.ownerSaysOnce ? .none : modelCadence)
                // La fecha sale de lo que dijo el dueño (en N minutos > día > hora),
                // con la hora del modelo solo como base.
                let hour = args.hour("hour") ?? LocalWhen.defaultReminderHour
                guard let base = calendar.date(bySettingHour: hour, minute: 0, second: 0,
                                               of: calendar.startOfDay(for: now)) else {
                    return invalid(missing("when", "formato 'YYYY-MM-DD HH:MM', hora local"))
                }
                if let unsupported = when.unsupportedCadence {
                    return reminder(text: statement, at: when.firstOccurrence(of: unsupported, modelDate: base),
                                    cadence: .none, now: now, when: when, calendar: calendar, rollPastOnce: true)
                }
                return reminder(text: statement, at: when.withPlausibleHour(when.repaired(base)), cadence: cadence,
                                now: now, when: when, calendar: calendar, rollPastOnce: true)
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
            var days = args.raw("days").flatMap { Int($0.prefix { $0.isNumber }) }.map { min(max($0, 1), 30) } ?? 7
            // El rango que pidió el dueño: hasta el día que nombró o el fin de semana.
            if let needed = when.listDaysAhead { days = max(days, needed) }
            return .real(name: tool.realTool, input: .object(["action": .string("list"), "days_ahead": .int(days)]))

        case "add_calendar_event":
            guard let modelTitle = args.text("title") else { return invalid(missing("title", "el título de la cita")) }
            guard let modelStart = args.raw("start").flatMap({ when.parse($0, repair: false) }) else {
                return invalid(missing("start", "formato 'YYYY-MM-DD HH:MM', hora local"))
            }
            let modelEnd = args.raw("end").flatMap { when.parse($0, repair: false) }
            let start = when.eventStart(modelStart, modelEnd: modelEnd)
            // "recuérdame … la cita" es un recordatorio, no un evento (medido: el
            // 3B agendaba "Cita"); con "agéndame/calendario/evento" sí es agenda.
            let owner = LocalWhen.fold(ownerText)
            if when.ownerAsksForAReminder,
               !["agend", "calendario", "evento"].contains(where: owner.contains) {
                let text = reminderText(model: modelTitle, ownerText: ownerText)
                if let unsupported = when.unsupportedCadence {
                    return reminder(text: text, at: when.firstOccurrence(of: unsupported, modelDate: start),
                                    cadence: .none, now: now, when: when, calendar: calendar, rollPastOnce: true)
                }
                let cadence = when.ownerCadence ?? .none
                return reminder(text: text, at: when.withPlausibleHour(start), cadence: cadence, now: now, when: when,
                                calendar: calendar)
            }
            let title = eventTitle(model: modelTitle, ownerText: ownerText)
            let swapped = modelEnd.map { $0 < modelStart } ?? false
            let end = when.eventEnd(start: start, modelEnd: swapped ? modelStart : modelEnd)
            return .real(name: tool.realTool, input: .object([
                "action": .string("create"), "title": .string(title),
                "start": .string(when.isoLocal(start)), "end": .string(when.isoLocal(end)),
            ]))

        case "write_note" where when.ownerAsksForAReminder
            && !["anota", "apunta", "nota"].contains(where: LocalWhen.fold(ownerText).contains):
            // "recuérdame en 45 minutos apagar el horno" es un recordatorio (medido:
            // el 3B lo anotaba).
            let text = reminderText(model: args.text("content") ?? args.text("name") ?? "", ownerText: ownerText)
            guard !text.isEmpty,
                  let base = calendar.date(bySettingHour: LocalWhen.defaultReminderHour, minute: 0, second: 0,
                                           of: calendar.startOfDay(for: now)) else {
                return invalid(missing("content", "el texto de la nota"))
            }
            if let unsupported = when.unsupportedCadence {
                return reminder(text: text, at: when.firstOccurrence(of: unsupported, modelDate: base),
                                cadence: .none, now: now, when: when, calendar: calendar, rollPastOnce: true)
            }
            return reminder(text: text, at: when.withPlausibleHour(when.repaired(base)), cadence: when.ownerCadence ?? .none,
                            now: now, when: when, calendar: calendar, rollPastOnce: true)

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
        let text = withoutSchedule(text)
        return .real(name: "anima_reminders", input: .object([
            "action": .string("create"), "text": .string(text), "message": .string(spokenFallback(text)),
            "fire_at": .string(when.isoLocal(fireAt)), "repeat": .string(cadence.rawValue),
        ]))
    }

    /// El resultado que lee el modelo local: si el de la tool real es parco
    /// ("Anexado a 'compras'."), lo dice completo para que lo cuente bien.
    public static func present(_ result: ToolResult, local name: String, input: JSONValue, ownerText: String = "",
                               dates: AnimaDateText = AnimaDateText()) -> ToolResult {
        guard !result.isError else { return result }
        var presented = result
        switch name {
        case "remind_me", "declare_goal":
            guard input["action"]?.stringValue == "create" else { return result }
            let when = LocalWhen(now: Date(), calendar: dates.calendar, ownerText: ownerText)
            if let unsupported = when.unsupportedCadence {
                presented.content = result.content + " " + unsupportedNote(unsupported.phrase)
            } else if LocalWhen.words(LocalWhen.fold(when.scheduleText)).contains("hoy"),
                      let fire = input["fire_at"]?.stringValue.flatMap(dates.parseISODateTime),
                      !dates.calendar.isDateInToday(fire) {
                presented.content = result.content + " " + pastTodayNote()
            } else {
                return result
            }
        case "list_events":
            let when = LocalWhen(now: Date(), calendar: dates.calendar, ownerText: ownerText)
            presented.content = readableEvents(when.eventsInRequestedRange(result.content), dates: dates)
        case "write_note":
            guard let note = input["name"]?.stringValue, let content = input["content"]?.stringValue else { return result }
            presented.content = "Anotado en tu nota '\(note)': \(content)."
        case "add_calendar_event":
            guard let title = input["title"]?.stringValue,
                  let start = input["start"]?.stringValue.flatMap(dates.parseISODateTime) else { return result }
            let end = input["end"]?.stringValue.flatMap(dates.parseISODateTime)
            let df = DateFormatter()
            df.locale = Locale(identifier: "es_CO")
            df.timeZone = dates.calendar.timeZone
            df.dateFormat = "EEEE d 'de' MMMM"
            let hm = DateFormatter()
            hm.timeZone = dates.calendar.timeZone
            hm.dateFormat = "HH:mm"
            let span = end.map { "de \(hm.string(from: start)) a \(hm.string(from: $0))" } ?? "a las \(hm.string(from: start))"
            presented.content = "agendé «\(title)» el \(df.string(from: start)) \(span)."
        case "list_goals":
            presented.content = changeNote(ownerText, tab: "Metas") + readableGoals(result.content)
        case "list_reminders":
            presented.content = changeNote(ownerText, tab: "Recordatorios") + result.content
        default:
            return result
        }
        return presented
    }

    /// Borrar, cambiar o dar por logrado no tiene tool local: se dice dónde se
    /// hace (medido: "La meta de correr 10 km ya no está en el registro").
    static func changeNote(_ ownerText: String, tab: String) -> String {
        guard LocalWhen.asksToChange(ownerText) else { return "" }
        return "Eso no lo puedo cambiar desde aquí: hazlo en la tab \(tab). Lo que hay:\n"
    }

    /// "¿qué tengo pendiente?", "¿qué tengo hoy?", "¿qué hay?": el resumen combina
    /// recordatorios, metas activas y la agenda de hoy.
    /// Solo "pendiente(s)" o "qué tengo/qué hay" a secas, "hoy" o "para hoy": con
    /// otra referencia ("mañana", "esta semana", "el viernes") se queda el
    /// listado que pidió; nunca si la frase abre con un imperativo de creación.
    public static func asksForPending(_ ownerText: String) -> Bool {
        let owner = LocalWhen.fold(ownerText)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !LocalWhen.opensWithCreation(ownerText), !LocalWhen.asksToChange(ownerText) else { return false }
        if owner.firstMatch(of: /\bpendientes?\b/) != nil { return true }
        return owner.firstMatch(of: /\b(?:que tengo|que hay)(?: (?:para )?hoy)?$/) != nil
    }

    /// La tool de consulta que responde una pregunta sobre lo suyo ("¿qué hay
    /// esta semana?", "¿qué metas tengo?"), o nil si no es una consulta así.
    /// Con ella, el 3B no puede responder de memoria (medido: inventó "Almuerzo
    /// con Ana", el del ejemplo, para "qué hay esta semana").
    public static func queryTool(_ ownerText: String) -> String? {
        let owner = LocalWhen.fold(ownerText)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !owner.isEmpty, !LocalWhen.opensWithCreation(ownerText), !LocalWhen.asksToChange(ownerText) else { return nil }
        // "¿qué tengo que hacer…?", "¿hay que…?", "¿qué es…?", "¿qué opinas…?" no son consultas de lo suyo.
        if ["tengo que", "hay que", "que es", "que son", "que opinas", "que significa", "que piensas"]
            .contains(where: owner.contains) { return nil }
        // Categoría explícita: "mis metas", "qué recordatorios tengo", "qué citas hay el viernes".
        let category = /\b(?:mis|tus) (recordatorios|metas|eventos|citas|reuniones|pendientes|agenda)\b|\bmi (agenda|calendario)\b|\b(?:que|cuales|cuantos|cuantas) (recordatorios|metas|eventos|citas|reuniones|pendientes) (?:tengo|hay)\b|\b(?:que tengo|que hay) en (?:mi|la) (agenda|calendario)\b/
        if let m = owner.firstMatch(of: category) {
            let word = String(m.1 ?? m.2 ?? m.3 ?? m.4 ?? "")
            switch word {
            case "metas": return "list_goals"
            case "recordatorios", "pendientes": return "list_reminders"
            default: return "list_events"
            }
        }
        // El patrón corto: "qué tengo / qué hay" + (fin | hoy | un rango), el de asksForPending.
        if asksForPending(ownerText) || LocalWhen.isShortAgendaQuestion(owner) { return "list_reminders" }
        return nil
    }

    /// Una consulta general ("¿qué hay esta semana?", "¿qué tengo pendiente?"):
    /// se responde con el resumen combinado del rango.
    public static func asksForSummary(_ ownerText: String) -> Bool {
        if asksForPending(ownerText) { return true }
        // Sin categoría ("¿qué tengo mañana?", "¿qué hay esta semana?"): todo lo
        // de ese rango; con categoría ("¿qué metas tengo?"), su listado.
        let owner = LocalWhen.fold(ownerText).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return queryTool(ownerText) != nil && LocalWhen.isShortAgendaQuestion(owner)
    }

    /// Secciones "Recordatorios:", "Metas:" y "<rango> en tu agenda:" (las
    /// vacías se omiten); todo vacío ⇒ "No tienes nada pendiente <rango>.".
    /// Sin rango nombrado: todos los recordatorios y la agenda de hoy; con rango
    /// ("pendiente para mañana", "esta semana"): recordatorios y agenda de ese rango.
    static func pendingSummary(reminders: String?, goals: String?, events: String?, now: Date,
                                      range: LocalWhen.Range? = nil,
                                      dates: AnimaDateText = AnimaDateText()) -> String {
        let window = range ?? LocalWhen.Range.today(now, calendar: dates.calendar)
        func items(_ text: String?) -> [String] {
            (text ?? "").split(separator: "\n").filter { $0.hasPrefix("- ") }
                .map { String($0).replacing(/^- \[[^\]]*\]\s*/, with: "- ") }
        }
        let inRange = (events ?? "").split(separator: "\n").filter { line in
            guard let at = line.range(of: " @ ", options: .backwards),
                  let date = ISO8601DateFormatter().date(from: String(line[at.upperBound...])) else { return false }
            return window.contains(date)
        }.joined(separator: "\n")
        var r = items(reminders)
        if range != nil {
            r = r.filter { line in readableReminderDate(line, now: now, dates: dates).map(window.contains) ?? false }
        }
        let g = items(goals.map(readableGoals)), e = items(readableEvents(inRange, dates: dates))
        var sections: [String] = []
        if !r.isEmpty { sections.append((["Recordatorios:"] + r).joined(separator: "\n")) }
        if !g.isEmpty { sections.append((["Metas:"] + g).joined(separator: "\n")) }
        if !e.isEmpty { sections.append((["\(window.label.prefix(1).uppercased() + window.label.dropFirst()) en tu agenda:"] + e)
            .joined(separator: "\n")) }
        return sections.isEmpty ? "No tienes nada pendiente \(window.label)." : sections.joined(separator: "\n")
    }

    /// "- llamar al banco — miércoles 7 de octubre a las 09:00" ⇒ esa fecha.
    static func readableReminderDate(_ line: String, now: Date, dates: AnimaDateText) -> Date? {
        guard let m = LocalWhen.fold(line).firstMatch(of: /(\d{1,2}) de ([a-z]+) a las (\d{1,2}):(\d{2})/),
              let day = Int(m.1), let month = LocalWhen.months.firstIndex(of: String(m.2)).map({ $0 + 1 }),
              let hour = Int(m.3), let minute = Int(m.4) else { return nil }
        let year = dates.calendar.component(.year, from: now)
        var parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard var date = dates.calendar.date(from: parts) else { return nil }
        if date < dates.calendar.startOfDay(for: now) {
            parts.year = year + 1
            date = dates.calendar.date(from: parts) ?? date
        }
        return date
    }

    /// "hoy a las 12" cuando ya pasaron.
    public static func pastTodayNote() -> String {
        "Ojo: esa hora de hoy ya pasó, así que te lo puse para mañana."
    }

    /// Lo que se le dice al dueño cuando pidió una repetición que la app no hace.
    public static func unsupportedNote(_ phrase: String) -> String {
        "Ojo: «\(phrase)» aún no lo repito sola; te lo recuerdo esta vez."
    }

    /// "- [ABC:123] Dentista @ 2026-10-07T20:52:00Z" ⇒ "- Dentista — miércoles 7 de
    /// octubre a las 15:52" (hora local, sin ids: el 3B leía la Z como hora).
    static func readableEvents(_ text: String, dates: AnimaDateText) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_CO")
        df.timeZone = dates.calendar.timeZone
        df.dateFormat = "EEEE d 'de' MMMM 'a las' HH:mm"
        let iso = ISO8601DateFormatter()
        return text.split(separator: "\n").map { line -> String in
            guard line.hasPrefix("- ") else { return String(line) }
            let body = String(line.dropFirst(2)).replacing(/^\[[^\]]*\]\s*/, with: "")
            guard let at = body.range(of: " @ ", options: .backwards),
                  let date = iso.date(from: String(body[at.upperBound...])) else { return "- " + body }
            return "- \(body[..<at.lowerBound]) — \(df.string(from: date))"
        }.joined(separator: "\n")
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
        // ("recuérdame qué tengo que comprar" abre con creación: no es consulta.)
        let asks = !LocalWhen.opensWithCreation(ownerText)
            && (["qué ", "cuál", "cómo", "cuándo", "?", "¿"].contains(where: raw.contains)
                || ["que ", "cuales ", "cual ", "muestrame", "dime", "lista", "lee ", "leeme"].contains(where: owner.hasPrefix))
        // Borrar, cambiar o dar por logrado no es crear: sin tool local para eso,
        // la consulta se queda y el modelo responde (medido: "elimina mi meta" →
        // declaraba una meta inventada).
        let changes = LocalWhen.asksToChange(ownerText)
        guard !owner.isEmpty, !asks, !changes else { return name }
        let targets: [(String, [String])] = [
            ("remind_me", ["recuerdame", "recordarme", "recuerdeme"]),
            ("add_calendar_event", ["agendame", "agenda una", "agenda la", "agenda el"]),
            ("write_note", ["anota", "apunta", "toma nota"]),
            ("declare_goal", ["mi meta es", "mi objetivo es", "me propongo", "nueva meta"]),
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

    /// El fallo de una llamada inválida, dicho al dueño (nunca el texto interno
    /// del adapter): "no entendí la fecha y la hora".
    public static func ownerFacing(_ message: String) -> String {
        if message.contains("`when`") || message.contains("`start`") { return "no entendí la fecha y la hora" }
        if message.contains("`hour`") { return "no entendí la hora" }
        if message.contains("`repeat`") || message.contains("`checkin`") { return "no entendí cada cuánto" }
        if ["`text`", "`title`", "`content`", "`statement`"].contains(where: message.contains) {
            return "no entendí qué querías guardar"
        }
        return "no entendí bien el pedido"
    }

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
        let clean = text.trimmingCharacters(in: CharacterSet(charactersIn: "¡!¿?.,;: ").union(.whitespacesAndNewlines))
        return "Oye, acuérdate de \(clean.prefix(1).lowercased() + clean.dropFirst())."
    }

    /// El texto del recordatorio: el del modelo si nombra algo de lo que dijo el
    /// dueño; si no (medido: "tomar la pastilla", el del ejemplo, para "…que
    /// mañana es el examen"), lo que el dueño dictó.
    static func reminderText(model: String, ownerText: String) -> String {
        guard !ownerText.isEmpty else { return model }
        let owner = Set(OnDevicePromptBuilder.salientStems(ownerText))
        let named = OnDevicePromptBuilder.salientStems(model).contains { owner.contains($0) }
        return named ? model : (dictatedReminder(ownerText) ?? model)
    }

    /// "Pagar el viernes a las 9" ⇒ "Pagar": la fecha y la hora ya van en el
    /// recordatorio. Lo que va al inicio ("Mañana es el examen") se conserva.
    static func withoutSchedule(_ text: String) -> String {
        // Solo sale la expresión de fecha/hora; lo de antes y de después se queda.
        // "de/por la mañana" sueltos son franja, no el día: se protegen.
        var out = text.replacingOccurrences(of: "de la mañana", with: "\u{1}")
            .replacingOccurrences(of: "por la mañana", with: "\u{2}")
        let weekday = "(?:lunes|martes|mi[eé]rcoles|jueves|viernes|s[aá]bados?|domingos?)"
        let expression = try? Regex("(?i)\\s+(?:(?:para|de) )?(?:hoy|pasado mañana|mañana|el (?:próximo |proximo )?\(weekday)"
            + "|el \\d{1,2} de [a-záéíóú]+|a las? \\d{1,2}(?::\\d{2})?(?: ?[ap]\\.? ?m\\.?)?(?: \u{1}| de la (?:tarde|noche))?"
            + "|(?:en|dentro de) \\d+ (?:horas?|minutos?)|todos los (?:días|\(weekday))|cada (?:día|semana|mes|\(weekday))"
            + "|la (?:próxima|proxima) semana)(?=[\\s,.;:!?]|$)")
        while let expression, let match = out.firstMatch(of: expression), !match.range.isEmpty {
            out.replaceSubrange(match.range, with: "")
        }
        out = out.replacingOccurrences(of: "\u{1}", with: "de la mañana").replacingOccurrences(of: "\u{2}", with: "por la mañana")
        var words = out.split(separator: " ").map(String.init)
        while let last = words.last, ["para", "de", "el", "la", "a", "y"].contains(last.lowercased()) { words.removeLast() }
        let kept = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return kept.isEmpty ? text : kept
    }

    /// El título del evento: el del modelo si solo usa palabras del dueño; si
    /// inventa (medido: "Reunión de equipo" para "agéndame reunión el lunes"),
    /// lo dictado tras "agéndame", sin la fecha y la hora.
    static func eventTitle(model: String, ownerText: String) -> String {
        guard !ownerText.isEmpty else { return model }
        let owner = Set(OnDevicePromptBuilder.salientStems(ownerText))
        let invented = OnDevicePromptBuilder.salientStems(model).contains { !owner.contains($0) }
        guard invented, let dictated = dictatedEvent(ownerText) else { return model }
        return dictated.prefix(1).uppercased() + dictated.dropFirst()
    }

    static func dictatedEvent(_ ownerText: String) -> String? {
        // Se corta sobre el texto original (con sus mayúsculas: "con Pedro").
        guard let key = ownerText.firstMatch(of: /(?i)ag[eé]nd(?:a|ame)\s+(?:una?\s+|la\s+|el\s+)?/) else { return nil }
        var rest = String(ownerText[key.range.upperBound...])
        let cut = try? Regex("(?i)\\s+(?:hoy|mañana|pasado mañana|el (?:próximo |proximo )?(?:lunes|martes|mi[eé]rcoles|jueves|viernes|s[aá]bado|domingo|\\d)"
            + "|la (?:próxima|proxima) semana|el (?:próximo|proximo) mes|este |esta |a las? \\d|de \\d{1,2} a"
            + "|en \\S+ (?:horas?|minutos?)|para el|para mañana|para la (?:próxima|proxima) semana).*$")
        if let cut, let match = rest.firstMatch(of: cut) { rest = String(rest[..<match.range.lowerBound]) }
        let text = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return text.isEmpty ? nil : text
    }

    /// "recuérdame hoy a las 6 de la tarde que mañana es el examen" → "mañana es el examen".
    static func dictatedReminder(_ ownerText: String) -> String? {
        let lower = ownerText.lowercased()
        guard let key = lower.firstMatch(of: /recu[eé]rd(?:a|e)me|recordarme/) else { return nil }
        var rest = String(lower[key.range.upperBound...])
        let weekday = "(?:lunes|martes|mi[eé]rcoles|jueves|viernes|s[aá]bados?|domingos?)"
        let leading = try? Regex("^[\\s,:]*(?:hoy|pasado mañana|mañana|esta (?:tarde|noche)"
            + "|todos los días(?: laborales| laborables)?|cada \\S+ (?:días|semanas|meses)|cada (?:día|semana|mes)"
            + "|todos los \(weekday)|cada \(weekday)|los \(weekday)|el \(weekday)|el \\d{1,2} de \\w+(?: de \\d{4})?"
            + "|(?:en|dentro de) \\S+ (?:horas?|minutos?|min)(?: y media)?"
            + "|a las? \\d{1,2}(?::\\d{2})?(?: ?[ap]\\.? ?m\\.?)?(?: de la (?:mañana|tarde|noche))?"
            + "|de \\d{1,2} a \\d{1,2}(?: de la (?:mañana|tarde|noche))?|que|para)(?=[\\s,.:]|$)")
        while let leading, let match = rest.firstMatch(of: leading), !match.range.isEmpty {
            let token = rest[match.range].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            rest = String(rest[match.range.upperBound...])
            if token == "que" { break }   // lo que sigue a "que" es lo dictado
        }
        let text = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return text.isEmpty ? nil : text
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
        let folded = value.folding(options: .diacriticInsensitive, locale: nil)
        if let known = Self.cadenceSynonyms[folded] { return known }
        if folded.hasPrefix("every ") || folded.hasPrefix("cada ") { return ProactiveCadence.none }
        return nil
    }

    static let cadenceSynonyms: [String: ProactiveCadence] = [
        "none": .none, "no": .none, "ninguno": .none, "ninguna": .none, "nunca": .none, "once": .none,
        "una vez": .none, "null": .none,
        "daily": .daily, "diario": .daily, "diaria": .daily, "cada dia": .daily, "todos los dias": .daily,
        "day": .daily, "everyday": .daily,
        "weekdays": .weekdays, "weekday": .weekdays, "entre semana": .weekdays, "dias habiles": .weekdays,
        "laborables": .weekdays,
        "weekly": .weekly, "semanal": .weekly, "cada semana": .weekly, "week": .weekly, "semanalmente": .weekly,
        // Lo que la app no repite: una vez (nunca diario/semanal inventado).
        "monthly": .none, "biweekly": .none, "fortnightly": .none, "mensual": .none, "quincenal": .none,
        "yearly": .none, "anual": .none,
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
        } else if let said = times(owner).first(where: \.afterLas), said.clock.hour == 12, parts.hour == 0 {
            parts.hour = 12   // "a las 12" no es medianoche
            parts.minute = said.clock.minute
        } else if let said = times(owner).first(where: \.afterLas), let hour = parts.hour,
                  hour % 12 != said.clock.hour % 12 {
            // "a las 10" y el modelo mandó otra hora (medido: 00:00): la del dueño;
            // 1-6 sin am/pm se lee de la tarde.
            parts.hour = (1...6).contains(said.clock.hour) ? said.clock.hour + 12 : said.clock.hour
            parts.minute = said.clock.minute
        }
        return calendar.date(from: parts) ?? date
    }

    /// Fin de un evento: "de 9 am a 11 am" ⇒ la última hora explícita del
    /// dueño; si no, el fin del modelo cuando es posterior al inicio; si no, 1 h.
    func eventEnd(start: Date, modelEnd: Date?) -> Date {
        if let range = ownerRange,
           let end = calendar.date(bySettingHour: range.end.hour, minute: range.end.minute, second: 0, of: start),
           end > start { return end }
        let times = explicitTimes(scheduleText)
        if times.count >= 2, let last = times.last,
           let end = calendar.date(bySettingHour: last.hour, minute: last.minute, second: 0, of: start), end > start {
            return end
        }
        if let modelEnd, modelEnd > start, modelEnd.timeIntervalSince(start) <= 12 * 3600 { return modelEnd }
        return start.addingTimeInterval(3600)
    }

    /// "de 12 a 1", "de 2 a 3 de la tarde", "de 9 am a 11 am": inicio y fin.
    /// Sin am/pm se lee horario de oficina (1-6 ⇒ tarde, 12 ⇒ mediodía).
    var ownerRange: (start: (hour: Int, minute: Int), end: (hour: Int, minute: Int))? {
        let owner = scheduleText
        guard let m = owner.firstMatch(of: /\bde (\d{1,2})\b(?::(\d{2}))?\s*(am|pm|a\.\s?m\.|p\.\s?m\.)? a (\d{1,2})\b(?::(\d{2}))?\s*(am|pm|a\.\s?m\.|p\.\s?m\.)?(?!\s*de (?:enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|octubre|noviembre|diciembre))/),
              let h1 = Int(m.1), let h2 = Int(m.4), (0...23).contains(h1), (0...23).contains(h2) else { return nil }
        let afternoon = owner.contains("de la tarde") || owner.contains("de la noche")
        func hour(_ raw: Int, _ meridiem: Substring?) -> Int {
            if let meridiem { return meridiem.hasPrefix("p") ? (raw < 12 ? raw + 12 : raw) : (raw == 12 ? 0 : raw) }
            if raw >= 13 { return raw }
            if afternoon { return raw < 12 ? raw + 12 : raw }
            return (1...6).contains(raw) ? raw + 12 : raw
        }
        var start = hour(h1, m.3 ?? m.6), end = hour(h2, m.6)
        if end <= start, end < 12 { end += 12 }
        if start > end, start >= 12, start - 12 < end { start -= 12 }
        return ((start, m.2.flatMap { Int($0) } ?? 0), (end, m.5.flatMap { Int($0) } ?? 0))
    }

    /// Inicio de un evento: el rango del dueño gana; si no, `repaired`.
    func eventStart(_ modelStart: Date, modelEnd: Date?) -> Date {
        var start = repaired(modelStart)
        if let range = ownerRange,
           let ranged = calendar.date(bySettingHour: range.start.hour, minute: range.start.minute, second: 0, of: start) {
            start = ranged
        } else if let modelEnd, explicitTimes(scheduleText).isEmpty, modelEnd < modelStart,
                  calendar.isDate(modelEnd, inSameDayAs: modelStart) {
            // El 3B invirtió inicio y fin (13:00–12:00).
            start = calendar.date(bySettingHour: calendar.component(.hour, from: modelEnd),
                                  minute: calendar.component(.minute, from: modelEnd), second: 0, of: start) ?? start
        }
        return start
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

    /// La repetición que dijo el dueño, o nil si no dijo ninguna (o pidió una
    /// que la app no hace: ver `unsupportedCadence`).
    var ownerCadence: ProactiveCadence? {
        let owner = Self.fold(ownerText)
        guard !owner.isEmpty, unsupportedCadence == nil else { return nil }
        if ["entre semana", "de lunes a viernes", "dias habiles", "dias laborales", "dias laborables"]
            .contains(where: owner.contains) { return .weekdays }
        if ["todos los dias", "cada dia", "diario", "diariamente", "a diario", "cada manana", "cada noche",
            "todas las mananas", "todas las noches"].contains(where: owner.contains) { return .daily }
        if ["cada semana", "semanal", "todas las semanas"].contains(where: owner.contains) || ownerWeekday != nil {
            return .weekly
        }
        return nil
    }

    /// Una repetición que `ProactiveCadence` no tiene: "cada 15 días", "cada 2
    /// semanas", "quincenal", "mensual", "cada mes".
    struct UnsupportedCadence: Equatable {
        var phrase: String
        var days: Int
        var months: Int
    }

    var unsupportedCadence: UnsupportedCadence? {
        let owner = Self.fold(ownerText)
        let numbers: [String: Int] = ["dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "diez": 10, "quince": 15,
                                      "veinte": 20, "treinta": 30]
        if let m = owner.firstMatch(of: /cada (\d{1,3}|dos|tres|cuatro|cinco|diez|quince|veinte|treinta) (dias|semanas|meses)/) {
            let n = Int(m.1) ?? numbers[String(m.1)] ?? 0
            guard n > 0 else { return nil }
            let phrase = Self.original(ownerText, matching: String(m.0)) ?? String(m.0)
            switch m.2 {
            case "dias": return n == 1 ? nil : UnsupportedCadence(phrase: phrase, days: n, months: 0)
            case "semanas": return n == 1 ? nil : UnsupportedCadence(phrase: phrase, days: 7 * n, months: 0)
            default: return UnsupportedCadence(phrase: phrase, days: 0, months: n)
            }
        }
        if owner.contains("quincenal") { return UnsupportedCadence(phrase: "quincenal", days: 15, months: 0) }
        for phrase in ["mensualmente", "mensual", "cada mes", "todos los meses"] where owner.contains(phrase) {
            return UnsupportedCadence(phrase: phrase, days: 0, months: 1)
        }
        return nil
    }

    /// Primera (y única) vez de una repetición no soportada: lo que dijo el
    /// dueño (día, "en N minutos") o, si no dijo cuándo empezar, dentro de un
    /// periodo; la hora del dueño, o la del modelo si es plausible, o la default.
    func firstOccurrence(of cadence: UnsupportedCadence, modelDate: Date) -> Date {
        let owner = scheduleText
        if offset(owner) != nil || day(owner) != nil { return withPlausibleHour(repaired(modelDate)) }
        let today = calendar.startOfDay(for: now)
        let later = cadence.months > 0
            ? calendar.date(byAdding: .month, value: cadence.months, to: today)
            : calendar.date(byAdding: .day, value: cadence.days, to: today)
        let hour = calendar.component(.hour, from: withPlausibleHour(modelDate))
        let clock = explicitTimes(owner).first ?? (ownerMentionsTime ? (hour, calendar.component(.minute, from: modelDate))
                                                                      : (Self.defaultReminderHour, 0))
        return calendar.date(bySettingHour: clock.0, minute: clock.1, second: 0, of: later ?? today) ?? modelDate
    }

    var offsetMinutes: Double? { offset(scheduleText).map { $0 / 60 } }

    /// Un rango de días con su nombre ("hoy", "mañana", "el viernes", "esta semana").
    struct Range: Sendable {
        var start: Date
        var end: Date
        var label: String

        func contains(_ date: Date) -> Bool { date >= start && date < end }

        static func today(_ now: Date, calendar: Calendar) -> Range {
            let start = calendar.startOfDay(for: now)
            return Range(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start, label: "hoy")
        }
    }

    /// El rango que nombró el dueño, o nil si no nombró ninguno.
    var requestedRange: Range? {
        let owner = scheduleText
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let toNextMonday = (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7
        let nextMonday = calendar.date(byAdding: .day, value: toNextMonday, to: today) ?? today
        if owner.contains("esta semana") {
            return Range(start: today, end: nextMonday, label: "esta semana")
        }
        let nextWeek = ["proxima semana", "otra semana", "semana que viene", "semana entrante"].contains(where: owner.contains)
        if nextWeek, Self.words(owner).allSatisfy({ Self.weekday($0) == nil }) {
            return Range(start: nextMonday, end: calendar.date(byAdding: .day, value: 7, to: nextMonday) ?? nextMonday,
                         label: "la próxima semana")
        }
        guard let day = day(owner) else { return nil }
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        let label: String
        switch offset {
        case 0: label = "hoy"
        case 1: label = "mañana"
        case 2 where owner.contains("pasado manana"): label = "pasado mañana"
        default:
            let df = DateFormatter()
            df.locale = Locale(identifier: "es_CO")
            df.timeZone = calendar.timeZone
            df.dateFormat = "EEEE d 'de' MMMM"
            label = "el " + df.string(from: day)
        }
        return Range(start: day, end: end, label: label)
    }

    /// Días a listar para lo que nombró el dueño ("mañana" ⇒ 2, "el viernes",
    /// "esta semana" ⇒ hasta el domingo), o nil.
    var listDaysAhead: Int? {
        guard let range = requestedRange else { return nil }
        return max(1, Int(ceil(range.end.timeIntervalSince(now) / 86_400)))
    }

    /// Las líneas del listado de la agenda dentro de lo que pidió el dueño: el
    /// día que nombró (mañana, el viernes) o todo si no nombró ninguno.
    func eventsInRequestedRange(_ text: String) -> String {
        // "esta semana" se corta en el domingo; un día nombrado, solo ese día.
        guard let range = requestedRange else { return text }
        let kept = text.split(separator: "\n").filter { line in
            guard let at = line.range(of: " @ ", options: .backwards),
                  let date = ISO8601DateFormatter().date(from: String(line[at.upperBound...])) else { return false }
            return range.contains(date)
        }
        return kept.isEmpty ? "No tienes nada en tu agenda \(range.label)." : kept.joined(separator: "\n")
    }

    /// La hora de un recordatorio cuando el dueño no dijo ninguna.
    static let defaultReminderHour = 9

    /// Sin hora dicha por el dueño, la del modelo es invento (medido: medianoche
    /// u 8:00 para "recuérdame mañana que…"): 9:00, como el check-in de las metas.
    func withPlausibleHour(_ date: Date) -> Date {
        guard !ownerText.isEmpty, !ownerMentionsTime, offset(scheduleText) == nil else { return date }
        return calendar.date(bySettingHour: Self.defaultReminderHour, minute: 0, second: 0, of: date) ?? date
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

    /// Borrar, cambiar o dar por logrado ("elimina mi meta", "ya cumplí…").
    /// Solo si el cambio es la intención principal: al inicio de la frase o
    /// sobre una meta/recordatorio/evento; nunca con un verbo de creación
    /// ("recuérdame el viernes cambiar el aceite" es un recordatorio).
    static func asksToChange(_ ownerText: String) -> Bool {
        let owner = fold(ownerText).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        // Primero la negación: "ya no quiero que me recuerdes…", "deja de recordarme…".
        if owner.firstMatch(of: /\b(?:no (?:quiero que )?me recuerdes|deja de recordarme|ya no me recuerdes|no me recuerdes)\b/) != nil {
            return true
        }
        // Un imperativo de creación como palabra, al inicio: es una creación.
        if opensWithCreation(ownerText) { return false }
        let verb = "(?:elimin|borr|cancel|quit|cambi|modific|cumpl|logr|termin|complet)\\w*"
        let opening = try? Regex("^(?:por favor,? |oye,? |ya )*(?:no (?:quiero|voy)|ya no|\(verb))")
        let object = try? Regex("\(verb)(?: \\w+){0,2} (?:mi|la|el|mis|las|los) (?:meta|metas|recordatorio|recordatorios|evento|eventos|cita|objetivo)")
        return (opening.map { owner.firstMatch(of: $0) != nil } ?? false)
            || (object.map { owner.firstMatch(of: $0) != nil } ?? false)
    }

    /// La frase abre con un imperativo de creación ("recuérdame…", "anota…").
    static func opensWithCreation(_ ownerText: String) -> Bool {
        let owner = fold(ownerText).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return owner.firstMatch(of: /^(?:(?:ya|oye|por favor),? )*(?:recuerdame|recordarme|recuerdeme|agendame|anota|anotame|apunta|apuntame|toma nota)\b/) != nil
    }

    /// La nota cuando el dueño pidió cambiar algo y el turno terminó sin tool
    /// (medido: "ya cumplí mi meta" ⇒ felicitaba y la meta seguía activa).
    static func changeHint(_ ownerText: String) -> String? {
        guard asksToChange(ownerText) else { return nil }
        let owner = fold(ownerText)
        if owner.contains("recordatorio") || owner.contains("recuerd") || owner.contains("recordarme") {
            return "Eso lo borras en la tab Recordatorios."
        }
        if ["evento", "cita", "agenda", "calendario"].contains(where: owner.contains) {
            return "Eso lo borras en tu app Calendario."
        }
        return owner.contains("cumpl") || owner.contains("logr") || owner.contains("termin")
            ? "Márcala como lograda en la tab Metas." : "Para cambiarla o borrarla, hazlo en la tab Metas."
    }

    /// "qué tengo / qué hay / tengo algo" + (fin | hoy | un rango), plegado.
    static func isShortAgendaQuestion(_ folded: String) -> Bool {
        folded.firstMatch(of: /^(?:y )?(?:que tengo|que hay|tengo algo)(?: pendientes?)?(?: (?:para )?(?:hoy|manana|pasado manana|esta semana|la proxima semana|el (?:proximo )?(?:lunes|martes|miercoles|jueves|viernes|sabado|domingo)|el \d{1,2} de [a-z]+))?$/) != nil
    }

    /// "recuérdame…" sin hablar de una meta.
    var ownerAsksForAReminder: Bool {
        let owner = Self.fold(ownerText)
        return ["recuerdame", "recordarme", "recuerdeme"].contains(where: owner.contains) && !owner.contains("meta")
            && !Self.asksToChange(ownerText)
    }

    var ownerMentionsTime: Bool { times(scheduleText).contains { $0.explicit || $0.afterLas } }
    var ownerExplicitTime: (hour: Int, minute: Int)? { explicitTimes(scheduleText).first }
    var ownerDay: Date? { day(scheduleText) }

    /// El tramo del texto original que corresponde a un tramo plegado (con tildes).
    static func original(_ text: String, matching folded: String) -> String? {
        let lower = text.lowercased()
        let chars = Array(lower)
        let target = Array(folded)
        guard target.count <= chars.count else { return nil }
        for start in 0...(chars.count - target.count) {
            let slice = String(chars[start..<start + target.count])
            if fold(slice) == folded { return slice }
        }
        return nil
    }

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

    /// "en 2 horas", "dentro de 30 minutos", "en una hora y media", "en media
    /// hora" ⇒ segundos.
    func offset(_ folded: String) -> TimeInterval? {
        let regex = /\b(?:en|dentro de) (\d{1,3}|un|una|media) (hora|horas|minuto|minutos|min)\b( y media)?/
        guard let match = folded.firstMatch(of: regex) else { return nil }
        var amount: Double
        switch match.1 {
        case "un", "una": amount = 1
        case "media": amount = 0.5
        default: amount = Double(match.1) ?? 0
        }
        guard amount > 0 else { return nil }
        let hours = match.2.hasPrefix("hora")
        if match.3 != nil, hours { amount += 0.5 }
        return hours ? amount * 3600 : amount * 60
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
        let nextWeek = ["proxima semana", "otra semana", "semana que viene", "semana entrante"].contains(where: text.contains)
        let current = calendar.component(.weekday, from: today)
        guard let weekday = words.lazy.compactMap(Self.weekday).first else {
            // "la próxima semana" sin día: el lunes siguiente.
            guard nextWeek else { return nil }
            return calendar.date(byAdding: .day, value: (2 - current + 7) % 7 == 0 ? 7 : (2 - current + 7) % 7, to: today)
        }
        if nextWeek {
            // El día pedido dentro de la semana siguiente (semana de lunes a domingo).
            let mondayOffset = (current + 5) % 7          // días desde el lunes de esta semana
            let nextMonday = calendar.date(byAdding: .day, value: 7 - mondayOffset, to: today) ?? today
            return calendar.date(byAdding: .day, value: (weekday + 5) % 7, to: nextMonday)
        }
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
        // \b: "15 de octubre" no puede partirse en un "1" con hora.
        let regex = /\b(\d{1,2})(?!\d)(?::(\d{2}))?\s*(a\.?\s?m\.?|p\.?\s?m\.?)?(?!\s*de (?:enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre))(?!\s*\/)(?!\s*(?:hora|horas|minuto|minutos|min)\b)/
        var out: [TimeMention] = []
        for match in text.matches(of: regex) {
            let before = text[..<match.range.lowerBound]
            if before.hasSuffix("/") || before.hasSuffix("en ") || before.hasSuffix("dentro de ") { continue }
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
