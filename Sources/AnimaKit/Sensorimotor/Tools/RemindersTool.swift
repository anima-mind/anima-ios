// RemindersTool.swift — tool `reminders` (§5.7) sobre EventKit reminders. Leer =
// aferente (allow); crear/completar = eferente (ask). Schema y clasificación
// puros; EKEventStore tras #if canImport(EventKit), degrada sin permiso (§8).

import Foundation

public struct RemindersTool: SensorimotorTool {
    public init() {}

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
        #if canImport(EventKit)
        return await RemindersBackend.run(action: action, input: input)
        #else
        return ToolResult(content: "Los recordatorios no están disponibles en esta plataforma.", isError: true)
        #endif
    }
}

#if canImport(EventKit)
import EventKit

enum RemindersBackend {
    static func run(action: String, input: JSONValue) async -> ToolResult {
        let store = EKEventStore()
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToReminders()
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

    private static func list(store: EKEventStore) async -> ToolResult {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        // Formatea a [String] (Sendable) DENTRO del completion: EKReminder no es Sendable.
        let lines: [String] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let df = ISO8601DateFormatter()
                let formatted = (reminders ?? []).prefix(50).map { reminder -> String in
                    let due = reminder.dueDateComponents?.date.map { " (vence \(df.string(from: $0)))" } ?? ""
                    return "- [\(reminder.calendarItemIdentifier)] \(reminder.title ?? "(sin título)")\(due)"
                }
                continuation.resume(returning: Array(formatted))
            }
        }
        guard !lines.isEmpty else {
            return ToolResult(content: "No hay recordatorios pendientes.")
        }
        return ToolResult(content: lines.joined(separator: "\n"))
    }

    private static func create(store: EKEventStore, input: JSONValue) -> ToolResult {
        guard let title = input["title"]?.stringValue, !title.isEmpty else {
            return ToolResult(content: "Error: falta 'title'.", isError: true)
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let dueStr = input["due"]?.stringValue, let due = ISO8601DateFormatter().date(from: dueStr) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
        }
        do {
            try store.save(reminder, commit: true)
            return ToolResult(content: "Recordatorio '\(title)' creado (id \(reminder.calendarItemIdentifier)).")
        } catch {
            return ToolResult(content: "No se pudo crear el recordatorio: \(error.localizedDescription)", isError: true)
        }
    }

    private static func complete(store: EKEventStore, reminderId: String?) -> ToolResult {
        guard let reminderId,
              let reminder = store.calendarItem(withIdentifier: reminderId) as? EKReminder else {
            return ToolResult(content: "No se encontró el recordatorio indicado.", isError: true)
        }
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
            return ToolResult(content: "Recordatorio marcado como completado.")
        } catch {
            return ToolResult(content: "No se pudo actualizar el recordatorio: \(error.localizedDescription)", isError: true)
        }
    }
}
#endif
