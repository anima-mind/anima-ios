// WidgetActionInbox.swift — los botones de los widgets ("Hecho", "Sí, avancé").
//
// Decisión (camino seguro): la extensión NUNCA escribe en GRDB. Cada tap se
// guarda como un archivo propio en `<grupo>/Widgets/Actions/` (escritura
// atómica, un archivo por acción: sin contención ni locks con la app) y el
// widget se repinta al instante con el snapshot actualizado de forma optimista.
// La app aplica la cola con el MISMO ProactiveActionHandler de las
// notificaciones (y re-sincroniza los avisos locales): de inmediato cuando el
// intent corre en el proceso de la app (iOS lo despierta en background), y si
// no, al arrancar / volver a primer plano / en el pulso de background.

import Foundation

public struct WidgetAction: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: Codable, Equatable, Sendable {
        case reminderDone(reminderId: String)
        case checkInProgress(goalId: String)
    }

    public var id: String
    public var kind: Kind
    public var createdAt: Date

    public init(id: String = UUID().uuidString, kind: Kind, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
    }
}

public struct WidgetActionInbox: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `<grupo>/Widgets/Actions` o nil sin App Group.
    public static func shared() -> WidgetActionInbox? {
        AppGroup.widgetsDirectory().map { WidgetActionInbox(directory: $0.appendingPathComponent("Actions")) }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private func fileURL(_ action: WidgetAction) -> URL {
        let stamp = String(format: "%013.0f", action.createdAt.timeIntervalSince1970 * 1000)
        return directory.appendingPathComponent("\(stamp)-\(action.id).json")
    }

    /// Durable antes de responder al tap (atómico: nunca un archivo a medias).
    public func enqueue(_ action: WidgetAction) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try Self.encoder().encode(action).write(to: fileURL(action), options: options)
    }

    /// Pendientes en orden de llegada. Un archivo que no se puede leer se salta
    /// sin borrarlo: antes del primer desbloqueo la protección de datos lo
    /// esconde y sigue siendo un tap válido (se aplica en el próximo drenaje).
    public func pending() -> [(url: URL, action: WidgetAction)] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let action = try? decoder.decode(WidgetAction.self, from: data) else { return nil }
                return (url, action)
            }
    }

    /// Aplica cada pendiente con `apply` y lo saca de la cola. Una acción que
    /// ya no aplica (recordatorio cerrado, meta borrada) también sale: reaplicar
    /// es idempotente del lado de los stores. Devuelve cuántas se aplicaron.
    @discardableResult
    public func drain(_ apply: @Sendable (WidgetAction) async -> Bool) async -> Int {
        var applied = 0
        for item in pending() {
            if await apply(item.action) { applied += 1 }
            try? FileManager.default.removeItem(at: item.url)
        }
        return applied
    }
}

// MARK: - Repintado optimista

extension WidgetSnapshot {
    /// El snapshot como quedará cuando la app aplique la acción: el widget no
    /// espera a la app para mostrar el tap.
    public func applying(_ action: WidgetAction, calendar: Calendar = .current) -> WidgetSnapshot {
        var copy = self
        let now = action.createdAt
        switch action.kind {
        case .reminderDone(let id):
            guard let index = copy.reminders.firstIndex(where: { $0.id == id }) else { return copy }
            let reminder = copy.reminders[index]
            if reminder.cadence == .none || reminder.delivered {
                copy.reminders.remove(at: index)
            } else if let next = reminder.cadence.nextOccurrence(after: max(now, reminder.fireAt), of: reminder.fireAt,
                                                                       calendar: calendar) {
                copy.reminders[index].fireAt = next
            }
        case .checkInProgress(let goalId):
            guard let index = copy.goals.firstIndex(where: { $0.id == goalId }) else { return copy }
            let goal = copy.goals[index]
            let current = Self.streak(of: goal, at: now, calendar: calendar)
            let progressedToday = goal.lastProgressAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false
            copy.goals[index].streak = progressedToday ? max(current, 1) : current + 1
            copy.goals[index].lastProgressAt = now
            copy.goals[index].lastAnsweredAt = now
        }
        return copy
    }
}
