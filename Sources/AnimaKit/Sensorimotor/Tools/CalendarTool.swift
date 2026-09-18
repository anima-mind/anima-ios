// CalendarTool.swift — tool `calendar` (§5.7) sobre EventKit. Leer = aferente
// (allow); crear/borrar = eferente (ask; borrar SIEMPRE ask, §5.7). El schema y
// la clasificación de operación son puros (testeables); el acceso a EKEventStore
// va tras #if canImport(EventKit) y degrada elegante sin permiso (§8).

import Foundation

public struct CalendarTool: SensorimotorTool {
    public init() {}

    private static let readOps: Set<String> = ["list", "search"]

    public var spec: ToolSpec {
        .client(
            name: "calendar",
            description: """
                Calendario del dueño (EventKit). Acciones: list (próximos eventos en \
                N días), search (por texto), create (nuevo evento), delete (borrar por \
                id). Crear y borrar requieren confirmación del dueño. Fechas en ISO 8601.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array([.string("list"), .string("search"), .string("create"), .string("delete")]),
                        "description": .string("Operación a realizar."),
                    ]),
                    "days_ahead": .object([
                        "type": .string("integer"),
                        "description": .string("Ventana para list (default 7)."),
                    ]),
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Texto a buscar en title/notes (para search)."),
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Título del evento (para create)."),
                    ]),
                    "start": .object([
                        "type": .string("string"),
                        "description": .string("Inicio ISO 8601 (para create)."),
                    ]),
                    "end": .object([
                        "type": .string("string"),
                        "description": .string("Fin ISO 8601 (para create)."),
                    ]),
                    "event_id": .object([
                        "type": .string("string"),
                        "description": .string("Identificador del evento (para delete)."),
                    ]),
                ]),
                "required": .array([.string("action")]),
                "additionalProperties": .bool(false),
            ]))
    }

    public func kind(for input: JSONValue) -> ToolKind {
        let action = input["action"]?.stringValue ?? ""
        return Self.readOps.contains(action) ? .afferent : .efferent
    }

    public func operation(for input: JSONValue) -> String {
        input["action"]?.stringValue ?? "default"
    }

    public func confirmationSummary(for input: JSONValue) -> String {
        switch input["action"]?.stringValue {
        case "create":
            let title = input["title"]?.stringValue ?? "(sin título)"
            let start = input["start"]?.stringValue ?? "?"
            return "Crear evento '\(title)' el \(start)"
        case "delete":
            return "Borrar el evento \(input["event_id"]?.stringValue ?? "?")"
        default:
            return "calendar: \(operation(for: input))"
        }
    }

    public func execute(_ input: JSONValue) async -> ToolResult {
        guard let action = input["action"]?.stringValue else {
            return ToolResult(content: "Error: falta 'action'.", isError: true)
        }
        #if canImport(EventKit)
        return await CalendarBackend.run(action: action, input: input)
        #else
        return ToolResult(content: "El calendario no está disponible en esta plataforma.", isError: true)
        #endif
    }
}

#if canImport(EventKit)
import EventKit

enum CalendarBackend {
    static func run(action: String, input: JSONValue) async -> ToolResult {
        let store = EKEventStore()
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToEvents()
        } catch {
            return ToolResult(content: "Sin acceso al calendario: \(error.localizedDescription)", isError: true)
        }
        guard granted else {
            return ToolResult(content: "El dueño no ha concedido acceso al calendario.", isError: true)
        }

        switch action {
        case "list":
            let days = intValue(input["days_ahead"]) ?? 7
            return list(store: store, daysAhead: days, query: nil)
        case "search":
            return list(store: store, daysAhead: 90, query: input["query"]?.stringValue)
        case "create":
            return create(store: store, input: input)
        case "delete":
            return delete(store: store, eventId: input["event_id"]?.stringValue)
        default:
            return ToolResult(content: "Acción de calendario desconocida: \(action)", isError: true)
        }
    }

    private static func list(store: EKEventStore, daysAhead: Int, query: String?) -> ToolResult {
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: max(1, daysAhead), to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        var events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        if let query, !query.isEmpty {
            let q = query.lowercased()
            events = events.filter {
                ($0.title?.lowercased().contains(q) ?? false) || ($0.notes?.lowercased().contains(q) ?? false)
            }
        }
        guard !events.isEmpty else {
            return ToolResult(content: "No hay eventos en el rango solicitado.")
        }
        let df = ISO8601DateFormatter()
        let lines = events.prefix(50).map { event -> String in
            let start = df.string(from: event.startDate)
            return "- [\(event.eventIdentifier ?? "?")] \(event.title ?? "(sin título)") @ \(start)"
        }
        return ToolResult(content: lines.joined(separator: "\n"))
    }

    private static func create(store: EKEventStore, input: JSONValue) -> ToolResult {
        guard let title = input["title"]?.stringValue, !title.isEmpty else {
            return ToolResult(content: "Error: falta 'title'.", isError: true)
        }
        let df = ISO8601DateFormatter()
        guard let startStr = input["start"]?.stringValue, let start = df.date(from: startStr) else {
            return ToolResult(content: "Error: 'start' inválido (usa ISO 8601).", isError: true)
        }
        let end = input["end"]?.stringValue.flatMap { df.date(from: $0) }
            ?? start.addingTimeInterval(3600)
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent)
            return ToolResult(content: "Evento '\(title)' creado (id \(event.eventIdentifier ?? "?")).")
        } catch {
            return ToolResult(content: "No se pudo crear el evento: \(error.localizedDescription)", isError: true)
        }
    }

    private static func delete(store: EKEventStore, eventId: String?) -> ToolResult {
        guard let eventId, let event = store.event(withIdentifier: eventId) else {
            return ToolResult(content: "No se encontró el evento indicado.", isError: true)
        }
        do {
            try store.remove(event, span: .thisEvent)
            return ToolResult(content: "Evento borrado.")
        } catch {
            return ToolResult(content: "No se pudo borrar el evento: \(error.localizedDescription)", isError: true)
        }
    }

    private static func intValue(_ value: JSONValue?) -> Int? {
        if case .int(let n) = value { return n }
        return nil
    }
}
#endif
