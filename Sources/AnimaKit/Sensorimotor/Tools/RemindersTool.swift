// RemindersTool.swift — tool `reminders` (§5.7) sobre EventKit reminders. Leer =
// aferente (allow); crear/completar = eferente (ask). Schema, clasificación y
// lógica de acciones puros contra `RemindersStore`; el adaptador EKEventStore va
// tras #if canImport(EventKit), degrada sin permiso (§8).

import Foundation

public struct RemindersTool: SensorimotorTool {
    private let makeStore: @Sendable () -> (any RemindersStore)?

    public init() {
        self.init(makeStore: RemindersTool.systemStore)
    }

    /// Inyección para tests: el store se crea por ejecución (como EKEventStore).
    init(makeStore: @escaping @Sendable () -> (any RemindersStore)?) {
        self.makeStore = makeStore
    }

    static let systemStore: @Sendable () -> (any RemindersStore)? = {
        #if canImport(EventKit)
        return EventKitRemindersStore()
        #else
        return nil
        #endif
    }

    private static let readOps: Set<String> = ["list"]

    public var spec: ToolSpec {
        .client(
            name: "reminders",
            description: """
                Recordatorios del dueño (EventKit). Acciones: list (pendientes o \
                vencidos), create (nuevo recordatorio con fecha opcional), complete \
                (marcar como hecho por id). Crear y completar requieren confirmación.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array([.string("list"), .string("create"), .string("complete")]),
                        "description": .string("Operación a realizar."),
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Título (para create)."),
                    ]),
                    "due": .object([
                        "type": .string("string"),
                        "description": .string("Fecha de vencimiento ISO 8601 (para create, opcional)."),
                    ]),
                    "reminder_id": .object([
                        "type": .string("string"),
                        "description": .string("Identificador del recordatorio (para complete)."),
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
            let due = input["due"]?.stringValue.map { " (vence \($0))" } ?? ""
            return "Crear recordatorio '\(title)'\(due)"
        case "complete":
            return "Marcar como completado el recordatorio \(input["reminder_id"]?.stringValue ?? "?")"
        default:
            return "reminders: \(operation(for: input))"
        }
    }

    public func execute(_ input: JSONValue) async -> ToolResult {
        guard let action = input["action"]?.stringValue else {
            return ToolResult(content: "Error: falta 'action'.", isError: true)
        }
        guard let store = makeStore() else {
            return ToolResult(content: "Los recordatorios no están disponibles en esta plataforma.", isError: true)
        }
        return await RemindersActions.run(action: action, input: input, store: store)
    }
}

// MARK: - Store (frontera con EventKit)

/// Recordatorio reducido a valores (EKReminder no es Sendable).
struct ReminderRecord: Sendable, Equatable {
    var id: String
    var title: String?
    var due: Date?
}

protocol RemindersStore: Sendable {
    func requestAccess() async throws -> Bool
    func incompleteReminders() async -> [ReminderRecord]
    /// Devuelve el identificador del recordatorio creado.
    func createReminder(title: String, due: DateComponents?) throws -> String
    /// false si no existe un recordatorio con ese id.
    func completeReminder(id: String) throws -> Bool
}

// MARK: - Lógica de acciones (pura respecto a EventKit)

enum RemindersActions {
    static let maxListed = 50

    static func run(action: String, input: JSONValue, store: any RemindersStore) async -> ToolResult {
        let granted: Bool
        do {
            granted = try await store.requestAccess()
        } catch {
            return ToolResult(content: "Sin acceso a recordatorios: \(error.localizedDescription)", isError: true)
        }
        guard granted else {
            return ToolResult(content: "El dueño no ha concedido acceso a recordatorios.", isError: true)
        }

        switch action {
        case "list":
            return await list(store: store)
        case "create":
            return create(store: store, input: input)
        case "complete":
            return complete(store: store, reminderId: input["reminder_id"]?.stringValue)
        default:
            return ToolResult(content: "Acción de recordatorios desconocida: \(action)", isError: true)
        }
    }

    static func list(store: any RemindersStore) async -> ToolResult {
        let df = ISO8601DateFormatter()
        let lines = await store.incompleteReminders().prefix(maxListed).map { reminder -> String in
            let due = reminder.due.map { " (vence \(df.string(from: $0)))" } ?? ""
            return "- [\(reminder.id)] \(reminder.title ?? "(sin título)")\(due)"
        }
        guard !lines.isEmpty else {
            return ToolResult(content: "No hay recordatorios pendientes.")
        }
        return ToolResult(content: lines.joined(separator: "\n"))
    }

    static func create(store: any RemindersStore, input: JSONValue) -> ToolResult {
        guard let title = input["title"]?.stringValue, !title.isEmpty else {
            return ToolResult(content: "Error: falta 'title'.", isError: true)
        }
        let due = dueComponents(input["due"]?.stringValue)
        do {
            let id = try store.createReminder(title: title, due: due)
            return ToolResult(content: "Recordatorio '\(title)' creado (id \(id)).")
        } catch {
            return ToolResult(content: "No se pudo crear el recordatorio: \(error.localizedDescription)", isError: true)
        }
    }

    /// ISO 8601 → componentes a minuto (EventKit guarda el due como componentes).
    /// Fecha ausente o inválida → sin vencimiento.
    static func dueComponents(_ iso: String?, calendar: Calendar = .current) -> DateComponents? {
        guard let iso, let due = ISO8601DateFormatter().date(from: iso) else { return nil }
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due)
    }

    static func complete(store: any RemindersStore, reminderId: String?) -> ToolResult {
        let notFound = ToolResult(content: "No se encontró el recordatorio indicado.", isError: true)
        guard let reminderId else { return notFound }
        do {
            return try store.completeReminder(id: reminderId)
                ? ToolResult(content: "Recordatorio marcado como completado.") : notFound
        } catch {
            return ToolResult(content: "No se pudo actualizar el recordatorio: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Adaptador EventKit (solo device/Mac con permiso real)

#if canImport(EventKit)
import EventKit

final class EventKitRemindersStore: RemindersStore, @unchecked Sendable {
    private let store = EKEventStore()

    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToReminders()
    }

    func incompleteReminders() async -> [ReminderRecord] {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        // Reduce a valores Sendable DENTRO del completion: EKReminder no es Sendable.
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map {
                    ReminderRecord(id: $0.calendarItemIdentifier, title: $0.title, due: $0.dueDateComponents?.date)
                })
            }
        }
    }

    func createReminder(title: String, due: DateComponents?) throws -> String {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = store.defaultCalendarForNewReminders()
        reminder.dueDateComponents = due
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    func completeReminder(id: String) throws -> Bool {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
        return true
    }
}
#endif
