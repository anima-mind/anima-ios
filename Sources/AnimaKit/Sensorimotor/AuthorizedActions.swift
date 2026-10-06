// AuthorizedActions.swift — "Autorizar siempre" del sheet de confirmación (batch
// 5b #1/#6): el dueño marca una (tool, operación) como permitida y deja de
// preguntarse. Persistido en UserDefaults; se revoca en Ajustes → Skills →
// Permisos. Rechazar sigue siendo neutral (no aprende nada).

import Foundation

public final class AuthorizedActionsStore: @unchecked Sendable {
    public static let key = "anima.permissions.always"
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var entries: Set<AllowlistEntry> {
        lock.lock(); defer { lock.unlock() }
        let raw = defaults.stringArray(forKey: Self.key) ?? []
        return Set(raw.compactMap { item in
            let parts = item.split(separator: "|", maxSplits: 1).map(String.init)
            return parts.count == 2 ? AllowlistEntry(tool: parts[0], operation: parts[1]) : nil
        })
    }

    public func allow(_ entry: AllowlistEntry) { write(entries.union([entry])) }
    public func revoke(_ entry: AllowlistEntry) { write(entries.subtracting([entry])) }

    private func write(_ set: Set<AllowlistEntry>) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(set.map { "\($0.tool)|\($0.operation)" }.sorted(), forKey: Self.key)
    }
}

/// Nombres para humanos en el sheet y en la lista de permisos.
public enum ToolNames {
    public static func friendly(_ tool: String) -> String {
        switch tool {
        case "calendar": return "Calendario del iPhone"
        case "reminders": return "Recordatorios del iPhone"
        case "notes": return "Notas"
        case "camera": return "Cámara"
        case "audio": return "Micrófono"
        case "phone_context": return "Contexto del teléfono"
        case "glasses_show": return "Pantalla de las gafas"
        case "glasses_camera": return "Cámara de las gafas"
        case "anima_reminders": return "Recordatorios de Anima"
        case "goals": return "Metas"
        default: return tool
        }
    }

    public static func operation(_ op: String) -> String {
        switch op {
        case "create", "add", "declare": return "crear"
        case "update", "edit", "set_checkin", "snooze": return "modificar"
        case "delete", "remove", "cancel", "clear_checkin": return "borrar"
        case "complete", "mark_achieved": return "marcar hecho"
        case "list", "read", "search": return "leer"
        case "capture", "photo": return "tomar foto"
        case "show": return "mostrar"
        default: return op
        }
    }

    /// "Calendario del iPhone · crear".
    public static func context(tool: String, operation: String) -> String {
        "\(friendly(tool)) · \(self.operation(operation))"
    }
}
