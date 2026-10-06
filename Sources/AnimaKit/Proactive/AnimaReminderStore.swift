// AnimaReminderStore.swift — los recordatorios PERSONALES de Anima: viven en su
// SQLite (no en EventKit), los entrega ella con su nombre y al tocarlos se sigue
// la conversación. Actor sobre la DatabaseQueue compartida; reloj y calendario
// inyectables (tests deterministas).

import Foundation
import GRDB

/// Cadencia compartida por recordatorios y check-ins.
public enum ProactiveCadence: String, Sendable, Codable, Equatable, CaseIterable {
    case none, daily, weekdays, weekly

    /// "cada día", "entre semana", "cada semana" (nil si no se repite).
    public var phrase: String? {
        switch self {
        case .none: return nil
        case .daily: return "cada día"
        case .weekdays: return "entre semana"
        case .weekly: return "cada semana"
        }
    }
}

public struct AnimaReminder: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Equatable {
        case scheduled, fired, done, cancelled
    }

    public var id: String
    public var text: String
    /// Lo que ella dice al entregarlo, en su voz (nil en recordatorios viejos).
    public var message: String?
    public var fireAt: Date
    public var repeatCadence: ProactiveCadence
    public var goalId: String?
    public var status: Status
    public var originSessionId: String?
    public var createdAt: Date
    public var firedAt: Date?
    public var doneAt: Date?

    /// El cuerpo del push y de la card del chat: su voz, o el fallback.
    public var spokenMessage: String {
        if let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            return message
        }
        return "Te recuerdo: \(text)"
    }
}

public enum AnimaReminderError: Error, Equatable, LocalizedError {
    case emptyText
    case pastFireAt
    case notFound
    case notActive
    case unknownGoal
    case invalidMinutes

    public var errorDescription: String? {
        switch self {
        case .emptyText: return "el texto del recordatorio está vacío"
        case .pastFireAt: return "la fecha ya pasó; usa una fecha futura"
        case .notFound: return "no existe un recordatorio con ese id"
        case .notActive: return "el recordatorio ya está cerrado (hecho o cancelado)"
        case .unknownGoal: return "no existe una meta con ese goal_id"
        case .invalidMinutes: return "los minutos deben ser mayores que 0"
        }
    }
}

public actor AnimaReminderStore {
    public enum Filter: Sendable {
        case upcoming, fired, all
    }

    private let queue: DatabaseQueue
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(queue: DatabaseQueue, calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.queue = queue
        self.calendar = calendar
        self.now = now
    }

    // MARK: - Alta

    @discardableResult
    public func create(text: String, message: String? = nil, fireAt: Date, repeat cadence: ProactiveCadence = .none,
                       goalId: String? = nil, originSessionId: String? = nil) throws -> AnimaReminder {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AnimaReminderError.emptyText }
        let ts = now()
        guard fireAt > ts else { throw AnimaReminderError.pastFireAt }
        if let goalId {
            let exists = try queue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM goal WHERE id=?", arguments: [goalId]) ?? 0
            }
            guard exists > 0 else { throw AnimaReminderError.unknownGoal }
        }
        let spoken = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reminder = AnimaReminder(id: UUID().uuidString, text: trimmed,
                                     message: spoken?.isEmpty == false ? spoken : nil, fireAt: fireAt,
                                     repeatCadence: cadence, goalId: goalId, status: .scheduled,
                                     originSessionId: originSessionId, createdAt: ts, firedAt: nil, doneAt: nil)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO anima_reminder (id, text, message, fire_at, repeat, goal_id, status, origin_session_id,
                                            created_at)
                VALUES (?,?,?,?,?,?,?,?,?)
                """, arguments: [reminder.id, reminder.text, reminder.message, fireAt.timeIntervalSince1970,
                                 cadence.rawValue,
                                 goalId, reminder.status.rawValue, originSessionId, ts.timeIntervalSince1970])
        }
        return reminder
    }

    // MARK: - Lectura

    public func reminder(id: String) -> AnimaReminder? {
        (try? queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM anima_reminder WHERE id=?", arguments: [id]).map(Self.reminder(from:))
        }) ?? nil
    }

    public func list(_ filter: Filter = .upcoming, limit: Int = 100) -> [AnimaReminder] {
        let sql: String
        switch filter {
        case .upcoming: sql = "SELECT * FROM anima_reminder WHERE status='scheduled' ORDER BY fire_at ASC LIMIT ?"
        case .fired: sql = "SELECT * FROM anima_reminder WHERE status='fired' ORDER BY fired_at DESC LIMIT ?"
        case .all: sql = "SELECT * FROM anima_reminder ORDER BY fire_at DESC LIMIT ?"
        }
        return (try? queue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: [limit]).map(Self.reminder(from:))
        }) ?? []
    }

    public func scheduledCount() -> Int {
        (try? queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM anima_reminder WHERE status='scheduled'")
        }).flatMap { $0 } ?? 0
    }

    /// Vencidos sin entregar: `scheduled` con fire_at ≤ now (más viejo primero).
    public func dueNow(now reference: Date? = nil) -> [AnimaReminder] {
        let ts = (reference ?? now()).timeIntervalSince1970
        return (try? queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM anima_reminder WHERE status='scheduled' AND fire_at <= ? ORDER BY fire_at ASC
                """, arguments: [ts]).map(Self.reminder(from:))
        }) ?? []
    }

    // MARK: - Transiciones

    /// Entregado: uno-a-uno pasa a `fired`; uno que se repite queda `scheduled`
    /// con fire_at en la próxima ocurrencia posterior a ahora.
    @discardableResult
    public func markFired(id: String) -> AnimaReminder? {
        guard let current = reminder(id: id), current.status == .scheduled else { return nil }
        let ts = now()
        if let next = Self.nextOccurrence(after: max(ts, current.fireAt), of: current.fireAt,
                                          repeat: current.repeatCadence, calendar: calendar) {
            update(id: id, sql: "UPDATE anima_reminder SET fired_at=?, fire_at=? WHERE id=?",
                   arguments: [ts.timeIntervalSince1970, next.timeIntervalSince1970, id])
        } else {
            update(id: id, sql: "UPDATE anima_reminder SET status='fired', fired_at=? WHERE id=?",
                   arguments: [ts.timeIntervalSince1970, id])
        }
        return reminder(id: id)
    }

    /// Hecho. En uno que se repite marca la ocurrencia; la serie sigue.
    @discardableResult
    public func complete(id: String) throws -> AnimaReminder {
        let current = try active(id)
        let ts = now().timeIntervalSince1970
        if current.repeatCadence == .none {
            update(id: id, sql: "UPDATE anima_reminder SET status='done', done_at=? WHERE id=?", arguments: [ts, id])
        } else {
            update(id: id, sql: "UPDATE anima_reminder SET done_at=? WHERE id=?", arguments: [ts, id])
        }
        return try found(id)
    }

    @discardableResult
    public func cancel(id: String) throws -> AnimaReminder {
        _ = try active(id)
        update(id: id, sql: "UPDATE anima_reminder SET status='cancelled' WHERE id=?", arguments: [id])
        return try found(id)
    }

    /// Pospone `minutes`. En uno que se repite NO mueve la serie: crea un
    /// recordatorio uno-a-uno con el mismo texto y lo devuelve.
    @discardableResult
    public func snooze(id: String, minutes: Int) throws -> AnimaReminder {
        guard minutes > 0 else { throw AnimaReminderError.invalidMinutes }
        let current = try active(id)
        let target = now().addingTimeInterval(TimeInterval(minutes * 60))
        if current.repeatCadence != .none {
            return try create(text: current.text, message: current.message, fireAt: target, goalId: current.goalId,
                              originSessionId: current.originSessionId)
        }
        update(id: id, sql: "UPDATE anima_reminder SET status='scheduled', fire_at=? WHERE id=?",
               arguments: [target.timeIntervalSince1970, id])
        return try found(id)
    }

    // MARK: - Repetición

    /// Próxima ocurrencia estrictamente posterior a `reference`, a la hora/minuto
    /// (y día de semana, si aplica) de `fireAt`. nil si no se repite.
    public static func nextOccurrence(after reference: Date, of fireAt: Date, repeat cadence: ProactiveCadence,
                                      calendar: Calendar) -> Date? {
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: fireAt)
        func next(weekday: Int?) -> Date? {
            var c = DateComponents()
            c.hour = parts.hour
            c.minute = parts.minute
            c.second = 0
            c.weekday = weekday
            return calendar.nextDate(after: reference, matching: c, matchingPolicy: .nextTime)
        }
        switch cadence {
        case .none: return nil
        case .daily: return next(weekday: nil)
        case .weekly: return next(weekday: parts.weekday)
        case .weekdays: return (2...6).compactMap { next(weekday: $0) }.min()
        }
    }

    /// Las próximas `count` ocurrencias desde fire_at (incluida) para programar
    /// notificaciones uno-a-uno sin depender de que la app se abra.
    public static func occurrences(of reminder: AnimaReminder, count: Int, calendar: Calendar) -> [Date] {
        guard reminder.status == .scheduled else { return [] }
        var out = [reminder.fireAt]
        guard reminder.repeatCadence != .none else { return out }
        while out.count < count, let next = nextOccurrence(after: out[out.count - 1], of: reminder.fireAt,
                                                         repeat: reminder.repeatCadence, calendar: calendar) {
            out.append(next)
        }
        return out
    }

    // MARK: - Internos

    private func active(_ id: String) throws -> AnimaReminder {
        let current = try found(id)
        guard current.status == .scheduled || current.status == .fired else { throw AnimaReminderError.notActive }
        return current
    }

    private func found(_ id: String) throws -> AnimaReminder {
        guard let current = reminder(id: id) else { throw AnimaReminderError.notFound }
        return current
    }

    private func update(id: String, sql: String, arguments: StatementArguments) {
        try? queue.write { db in try db.execute(sql: sql, arguments: arguments) }
    }

    static func reminder(from row: Row) -> AnimaReminder {
        AnimaReminder(
            id: row["id"],
            text: row["text"] ?? "",
            message: row["message"],
            fireAt: Date(timeIntervalSince1970: row["fire_at"]),
            repeatCadence: ProactiveCadence(rawValue: row["repeat"] ?? "none") ?? .none,
            goalId: row["goal_id"],
            status: AnimaReminder.Status(rawValue: row["status"] ?? "scheduled") ?? .scheduled,
            originSessionId: row["origin_session_id"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            firedAt: (row["fired_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            doneAt: (row["done_at"] as Double?).map(Date.init(timeIntervalSince1970:)))
    }
}
