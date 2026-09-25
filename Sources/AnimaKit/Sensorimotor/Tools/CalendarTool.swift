// CalendarTool.swift — tool `calendar` (§5.7) sobre EventKit. Leer = aferente
// (allow); crear/borrar = eferente (ask; borrar SIEMPRE ask, §5.7). El schema y
// la clasificación de operación son puros (testeables); el acceso a EKEventStore
// va tras #if canImport(EventKit) y degrada elegante sin permiso (§8).

import Foundation

public struct CalendarTool: SensorimotorTool {
    private let makeStore: @Sendable () -> (any CalendarStore)?

    public init() {
        self.init(makeStore: CalendarTool.systemStore)
    }

    /// Inyección para tests: el store se crea por ejecución (como EKEventStore).
    init(makeStore: @escaping @Sendable () -> (any CalendarStore)?) {
        self.makeStore = makeStore
    }

    static let systemStore: @Sendable () -> (any CalendarStore)? = {
        #if canImport(EventKit)
        return EventKitCalendarStore()
        #else
        return nil
        #endif
    }

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
        guard let store = makeStore() else {
            return ToolResult(content: "El calendario no está disponible en esta plataforma.", isError: true)
        }
        return await CalendarActions.run(action: action, input: input, store: store, now: Date())
    }
}

// MARK: - Store (frontera con EventKit)

/// Evento reducido a valores: EKEvent no es Sendable ni instanciable sin store.
struct CalendarEventRecord: Sendable, Equatable {
    var id: String?
    var title: String?
    var notes: String?
    var start: Date
}

protocol CalendarStore: Sendable {
    func requestAccess() async throws -> Bool
    func events(from start: Date, to end: Date) -> [CalendarEventRecord]
    /// Devuelve el identificador del evento creado.
    func createEvent(title: String, start: Date, end: Date) throws -> String?
    /// false si no existe un evento con ese id.
    func deleteEvent(id: String) throws -> Bool
}

// MARK: - Lógica de acciones (pura respecto a EventKit)

enum CalendarActions {
    static let searchWindowDays = 90
    static let maxListed = 50

    static func run(action: String, input: JSONValue, store: any CalendarStore, now: Date) async -> ToolResult {
        let granted: Bool
        do {
            granted = try await store.requestAccess()
        } catch {
            return ToolResult(content: "Sin acceso al calendario: \(error.localizedDescription)", isError: true)
        }
        guard granted else {
            return ToolResult(content: "El dueño no ha concedido acceso al calendario.", isError: true)
        }

        switch action {
        case "list":
            let days = intValue(input["days_ahead"]) ?? 7
            return list(store: store, now: now, daysAhead: days, query: nil)
        case "search":
            return list(store: store, now: now, daysAhead: searchWindowDays, query: input["query"]?.stringValue)
        case "create":
            return create(store: store, input: input)
        case "delete":
            return delete(store: store, eventId: input["event_id"]?.stringValue)
        default:
            return ToolResult(content: "Acción de calendario desconocida: \(action)", isError: true)
        }
    }

    static func list(store: any CalendarStore, now: Date, daysAhead: Int, query: String?) -> ToolResult {
        let end = Calendar.current.date(byAdding: .day, value: max(1, daysAhead), to: now) ?? now
        var events = store.events(from: now, to: end).sorted { $0.start < $1.start }
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
        let lines = events.prefix(maxListed).map { event -> String in
            "- [\(event.id ?? "?")] \(event.title ?? "(sin título)") @ \(df.string(from: event.start))"
        }
        return ToolResult(content: lines.joined(separator: "\n"))
    }

    static func create(store: any CalendarStore, input: JSONValue) -> ToolResult {
        guard let title = input["title"]?.stringValue, !title.isEmpty else {
            return ToolResult(content: "Error: falta 'title'.", isError: true)
        }
        let df = ISO8601DateFormatter()
        guard let startStr = input["start"]?.stringValue, let start = df.date(from: startStr) else {
            return ToolResult(content: "Error: 'start' inválido (usa ISO 8601).", isError: true)
        }
        let end = input["end"]?.stringValue.flatMap { df.date(from: $0) }
            ?? start.addingTimeInterval(3600)
        do {
            let id = try store.createEvent(title: title, start: start, end: end)
            return ToolResult(content: "Evento '\(title)' creado (id \(id ?? "?")).")
        } catch {
            return ToolResult(content: "No se pudo crear el evento: \(error.localizedDescription)", isError: true)
        }
    }

    static func delete(store: any CalendarStore, eventId: String?) -> ToolResult {
        let notFound = ToolResult(content: "No se encontró el evento indicado.", isError: true)
        guard let eventId else { return notFound }
        do {
            return try store.deleteEvent(id: eventId) ? ToolResult(content: "Evento borrado.") : notFound
        } catch {
            return ToolResult(content: "No se pudo borrar el evento: \(error.localizedDescription)", isError: true)
        }
    }

    private static func intValue(_ value: JSONValue?) -> Int? {
        if case .int(let n) = value { return n }
        return nil
    }
}

// MARK: - Adaptador EventKit (solo device/Mac con permiso real)

#if canImport(EventKit)
import EventKit

final class EventKitCalendarStore: CalendarStore, @unchecked Sendable {
    private let store = EKEventStore()

    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    func events(from start: Date, to end: Date) -> [CalendarEventRecord] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map {
            CalendarEventRecord(id: $0.eventIdentifier, title: $0.title, notes: $0.notes, start: $0.startDate)
        }
    }

    func createEvent(title: String, start: Date, end: Date) throws -> String? {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
        return event.eventIdentifier
    }

    func deleteEvent(id: String) throws -> Bool {
        guard let event = store.event(withIdentifier: id) else { return false }
        try store.remove(event, span: .thisEvent)
        return true
    }
}
#endif
