// OtherModel.swift — el modelo del deseo del dueño (§5.8). El Otro = Joshua. Actor
// sobre la DatabaseQueue compartida. Precedencia dura: stated > inferred >
// structural. Un goal inferred NUNCA motiva nada hasta que el dueño lo confirma:
// nace pending_confirmation y aparece en el MISMO inbox de Fase 3 ("Por aprobar")
// (un tipo de item nuevo, no una cola nueva). Confirmar → active; rechazar →
// abandoned. Los stated los extrae el Consolidator de las sesiones del ciclo con
// Haiku ("quiero X"); los inferred salen del reflection (Fase 3).

import Foundation
import GRDB

/// Origen de un goal y su precedencia dura (§5.8): stated > inferred > structural.
public enum GoalSource: String, Sendable, Codable, Equatable, CaseIterable {
    case stated, inferred, structural
    public var precedence: Int {
        switch self {
        case .stated: return 0
        case .inferred: return 1
        case .structural: return 2
        }
    }
}

public enum GoalStatus: String, Sendable, Codable, Equatable {
    case active, achieved, abandoned
    case pendingConfirmation = "pending_confirmation"
}

public enum CheckInAnswer: String, Sendable, Codable, Equatable, CaseIterable {
    case yes, partial, no, skipped

    /// Cuenta como avance (racha y predicado progress_check_in).
    public var isProgress: Bool { self == .yes || self == .partial }
}

/// Un check-in de una meta: preguntado (asked) y, si hubo, respondido.
public struct GoalCheckIn: Sendable, Equatable, Identifiable {
    public var id: String
    public var goalId: String
    public var askedAt: Date
    public var answeredAt: Date?
    public var answer: CheckInAnswer?
    public var note: String
}

/// Una meta del dueño, evaluable sin LLM contra el estado del teléfono.
public struct Goal: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var statement: String
    public var desiredState: ObservablePredicate
    public var source: GoalSource
    public var status: GoalStatus
    public var priority: Int
    public var evidence: String
    public var confirmedByOther: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var checkIn: CheckInCadence

    public init(id: String, statement: String, desiredState: ObservablePredicate,
                source: GoalSource, status: GoalStatus, priority: Int, evidence: String,
                confirmedByOther: Bool, createdAt: Date, updatedAt: Date, checkIn: CheckInCadence = .off) {
        self.id = id
        self.statement = statement
        self.desiredState = desiredState
        self.source = source
        self.status = status
        self.priority = priority
        self.evidence = evidence
        self.confirmedByOther = confirmedByOther
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.checkIn = checkIn
    }

    /// Un goal motiva acciones solo si está activo y, cuando es inferred, fue
    /// confirmado por el Otro (§5.8 mitigación 2). El DesireEngine solo lee estos.
    public var motivates: Bool {
        status == .active && (source != .inferred || confirmedByOther)
    }
}

public actor OtherModel {
    private let queue: DatabaseQueue
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(queue: DatabaseQueue, calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.queue = queue
        self.calendar = calendar
        self.now = now
    }

    // MARK: - Alta de metas

    /// Meta declarada por el dueño (la extrae el Consolidator del ciclo, o el chat).
    /// Nace ACTIVE (stated motiva de inmediato). Idempotente por statement: si ya
    /// existe una meta no-abandonada con el mismo enunciado, refuerza su evidencia.
    @discardableResult
    public func ingestStated(statement: String, desiredState: ObservablePredicate,
                             evidence: String, priority: Int = 5) -> String {
        upsert(statement: statement, desiredState: desiredState, source: .stated,
               status: .active, evidence: evidence, priority: priority, confirmed: false)
    }

    /// Meta estructural del harness (p.ej. "no perder pendientes"). Nace ACTIVE.
    @discardableResult
    public func addStructural(statement: String, desiredState: ObservablePredicate,
                              priority: Int = 3) -> String {
        upsert(statement: statement, desiredState: desiredState, source: .structural,
               status: .active, evidence: "meta estructural", priority: priority, confirmed: false)
    }

    /// Meta inferida por el reflection (§5.8): SIEMPRE nace pending_confirmation y
    /// NO motiva nada hasta que el dueño la confirme en el inbox.
    @discardableResult
    public func infer(statement: String, desiredState: ObservablePredicate,
                      evidence: String, priority: Int = 5) -> String {
        upsert(statement: statement, desiredState: desiredState, source: .inferred,
               status: .pendingConfirmation, evidence: evidence, priority: priority, confirmed: false)
    }

    private func upsert(statement: String, desiredState: ObservablePredicate, source: GoalSource,
                        status: GoalStatus, evidence: String, priority: Int, confirmed: Bool) -> String {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let ts = now().timeIntervalSince1970
        let predicateJSON = Self.encode(desiredState)
        let id = (try? queue.write { db -> String in
            if let existing = try Row.fetchOne(db, sql: """
                SELECT id FROM goal WHERE statement=? AND status != 'abandoned' LIMIT 1
                """, arguments: [trimmed]) {
                let gid: String = existing["id"]
                try db.execute(sql: "UPDATE goal SET evidence=?, updated_at=? WHERE id=?",
                               arguments: [evidence, ts, gid])
                return gid
            }
            let gid = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO goal (id, statement, predicate_json, source, status, priority, evidence,
                                  confirmed_by_other, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """, arguments: [gid, trimmed, predicateJSON, source.rawValue, status.rawValue,
                                 priority, evidence, confirmed ? 1 : 0, ts, ts])
            return gid
        }) ?? UUID().uuidString
        return id
    }

    // MARK: - El deseo vigente (lo único que lee el DesireEngine)

    /// Metas que MOTIVAN, en orden de precedencia (stated > inferred > structural),
    /// luego prioridad y luego staleness (la más vieja sin tocar primero).
    public func desire() -> [Goal] {
        allGoals().filter(\.motivates).sorted { a, b in
            if a.source.precedence != b.source.precedence { return a.source.precedence < b.source.precedence }
            if a.priority != b.priority { return a.priority > b.priority }
            return a.updatedAt < b.updatedAt
        }
    }

    // MARK: - Gate de confirmación (mismo inbox de Fase 3)

    /// Metas inferidas a la espera del dueño (§5.8): el ApprovalsInboxView las
    /// muestra como un tipo de item nuevo junto a los cambios de identidad.
    public func pendingConfirmations() -> [Goal] {
        allGoals().filter { $0.status == .pendingConfirmation }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// El dueño confirma una meta inferida → active + confirmedByOther. Recién
    /// entonces puede motivar un pulso.
    public func confirm(id: String) {
        let ts = now().timeIntervalSince1970
        try? queue.write { db in
            try db.execute(sql: """
                UPDATE goal SET status='active', confirmed_by_other=1, updated_at=?
                WHERE id=? AND status='pending_confirmation'
                """, arguments: [ts, id])
        }
    }

    /// El dueño rechaza (o abandona) una meta → abandoned (deja de existir para el deseo).
    public func abandon(id: String) {
        let ts = now().timeIntervalSince1970
        try? queue.write { db in
            try db.execute(sql: "UPDATE goal SET status='abandoned', updated_at=? WHERE id=?",
                           arguments: [ts, id])
        }
    }

    public func markAchieved(id: String) {
        let ts = now().timeIntervalSince1970
        try? queue.write { db in
            try db.execute(sql: "UPDATE goal SET status='achieved', updated_at=? WHERE id=?",
                           arguments: [ts, id])
        }
    }

    // MARK: - Check-in (opt-in por meta)

    /// Fija la cadencia del check-in. false si la meta no existe o la cadencia es inválida.
    @discardableResult
    public func setCheckIn(id: String, _ checkIn: CheckInCadence) -> Bool {
        guard checkIn.isValid else { return false }
        let ts = now().timeIntervalSince1970
        let changed = (try? queue.write { db -> Int in
            try db.execute(sql: """
                UPDATE goal SET checkin_cadence=?, checkin_hour=?, checkin_minute=?, checkin_weekday=?, updated_at=?
                WHERE id=?
                """, arguments: [checkIn.cadence.rawValue, checkIn.hour, checkIn.minute,
                                 checkIn.cadence == .weekly ? checkIn.weekday : nil, ts, id])
            return db.changesCount
        }) ?? 0
        return changed > 0
    }

    @discardableResult
    public func clearCheckIn(id: String) -> Bool {
        guard let goal = goal(id: id) else { return false }
        return setCheckIn(id: id, CheckInCadence(cadence: .none, hour: goal.checkIn.hour, minute: goal.checkIn.minute))
    }

    /// Anima preguntó (deep link del check-in): fila sin respuesta. nil si la meta no existe.
    @discardableResult
    public func markCheckInAsked(goalId: String) -> String? {
        guard goal(id: goalId) != nil else { return nil }
        let id = UUID().uuidString
        try? queue.write { db in
            try db.execute(sql: "INSERT INTO goal_checkin (id, goal_id, asked_at) VALUES (?,?,?)",
                           arguments: [id, goalId, now().timeIntervalSince1970])
        }
        return id
    }

    /// La respuesta del dueño (chat o acción de la notificación). Responde la
    /// pregunta abierta de las últimas 24h si la hay; si no, crea la fila.
    @discardableResult
    /// - answeredAt: cuándo respondió el dueño (un tap del widget aplicado
    ///   después); nil = ahora.
    /// - oncePerDay: reaplicar la misma respuesta ese día no agrega otra fila
    ///   (la cola de botones puede reaplicar una acción ya aplicada).
    public func recordCheckIn(goalId: String, answer: CheckInAnswer, note: String = "",
                              answeredAt: Date? = nil, oncePerDay: Bool = false) -> GoalCheckIn? {
        (try? applyCheckIn(goalId: goalId, answer: answer, note: note, answeredAt: answeredAt,
                           oncePerDay: oncePerDay)) ?? nil
    }

    /// Como `recordCheckIn`, pero distingue "la meta ya no existe" (nil) de "la
    /// base falló" (lanza): la cola de los widgets conserva el tap en el segundo.
    public func applyCheckIn(goalId: String, answer: CheckInAnswer, note: String = "",
                             answeredAt: Date? = nil, oncePerDay: Bool = false) throws -> GoalCheckIn? {
        let at = answeredAt ?? now()
        let ts = at.timeIntervalSince1970
        let dayStart = calendar.startOfDay(for: at).timeIntervalSince1970
        let dayEnd = (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: at)) ?? at)
            .timeIntervalSince1970
        let id = try queue.write { db -> String? in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM goal WHERE id=?)",
                                    arguments: [goalId]) == true else { return nil }
            if oncePerDay, let existing = try String.fetchOne(db, sql: """
                SELECT id FROM goal_checkin WHERE goal_id=? AND answer=? AND answered_at >= ? AND answered_at < ?
                ORDER BY answered_at LIMIT 1
                """, arguments: [goalId, answer.rawValue, dayStart, dayEnd]) {
                return existing
            }
            if let open = try String.fetchOne(db, sql: """
                SELECT id FROM goal_checkin WHERE goal_id=? AND answered_at IS NULL AND asked_at > ?
                ORDER BY asked_at DESC LIMIT 1
                """, arguments: [goalId, ts - 24 * 3600]) {
                try db.execute(sql: "UPDATE goal_checkin SET answered_at=?, answer=?, note=? WHERE id=?",
                               arguments: [ts, answer.rawValue, note, open])
                return open
            }
            let fresh = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO goal_checkin (id, goal_id, asked_at, answered_at, answer, note) VALUES (?,?,?,?,?,?)
                """, arguments: [fresh, goalId, ts, ts, answer.rawValue, note])
            return fresh
        }
        guard let id else { return nil }
        return try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM goal_checkin WHERE id=?", arguments: [id]).map(Self.checkIn(from:))
        }
    }

    public func lastCheckIn(goalId: String) -> GoalCheckIn? {
        checkIns(goalId: goalId, limit: 1).first
    }

    public func checkIns(goalId: String, limit: Int = 30) -> [GoalCheckIn] {
        (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM goal_checkin WHERE goal_id=? ORDER BY asked_at DESC LIMIT ?",
                             arguments: [goalId, limit]).map(Self.checkIn(from:))
        }) ?? []
    }

    /// ¿Ya respondió hoy (día local)? Evita repetir la pregunta en el chat.
    public func answeredToday(goalId: String) -> Bool {
        let start = calendar.startOfDay(for: now()).timeIntervalSince1970
        let count = (try? queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM goal_checkin WHERE goal_id=? AND answered_at >= ?",
                             arguments: [goalId, start])
        }).flatMap { $0 } ?? 0
        return count > 0
    }

    /// Días consecutivos (local) con avance (yes/partial), terminando hoy o ayer.
    public func streak(goalId: String) -> Int {
        let days = Set(progressDates(goalId: goalId).map { calendar.startOfDay(for: $0) })
        let today = calendar.startOfDay(for: now())
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return 0 }
        var cursor = days.contains(today) ? today : yesterday
        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    /// Días completos desde el último avance (yes/partial). nil si nunca hubo.
    public func daysSinceProgress(goalId: String) -> Int? {
        guard let last = progressDates(goalId: goalId).first else { return nil }
        return max(0, Int(now().timeIntervalSince(last) / 86_400))
    }

    /// Último avance (yes/partial). nil si nunca hubo.
    public func lastProgressAt(goalId: String) -> Date? {
        progressDates(goalId: goalId).first
    }

    /// Última respuesta del dueño (cualquier respuesta). nil si nunca respondió.
    public func lastAnsweredAt(goalId: String) -> Date? {
        (try? queue.read { db in
            try Double.fetchOne(db, sql: "SELECT MAX(answered_at) FROM goal_checkin WHERE goal_id=?",
                                arguments: [goalId])
        }).flatMap { $0 }.map(Date.init(timeIntervalSince1970:))
    }

    private func progressDates(goalId: String) -> [Date] {
        (try? queue.read { db in
            try Double.fetchAll(db, sql: """
                SELECT answered_at FROM goal_checkin
                WHERE goal_id=? AND answer IN ('yes','partial') AND answered_at IS NOT NULL
                ORDER BY answered_at DESC
                """, arguments: [goalId]).map(Date.init(timeIntervalSince1970:))
        }) ?? []
    }

    private func checkIn(id: String) -> GoalCheckIn? {
        (try? queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM goal_checkin WHERE id=?", arguments: [id]).map(Self.checkIn(from:))
        }) ?? nil
    }

    // MARK: - Lectura

    public func goal(id: String) -> Goal? {
        try? queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM goal WHERE id=?", arguments: [id]).map(Self.goal(from:))
        } ?? nil
    }

    public func allGoals() -> [Goal] {
        (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM goal ORDER BY created_at DESC").map(Self.goal(from:))
        }) ?? []
    }

    // MARK: - Serialización

    static func encode(_ predicate: ObservablePredicate) -> String {
        String(data: (try? JSONEncoder().encode(predicate)) ?? Data(), encoding: .utf8) ?? "{}"
    }

    static func decodePredicate(_ json: String) -> ObservablePredicate? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ObservablePredicate.self, from: data)
    }

    static func goal(from row: Row) -> Goal {
        let predicate = decodePredicate(row["predicate_json"] ?? "{}") ?? .remindersOverdue(atMost: 0)
        return Goal(
            id: row["id"],
            statement: row["statement"] ?? "",
            desiredState: predicate,
            source: GoalSource(rawValue: row["source"]) ?? .structural,
            status: GoalStatus(rawValue: row["status"]) ?? .active,
            priority: row["priority"] ?? 5,
            evidence: row["evidence"] ?? "",
            confirmedByOther: (row["confirmed_by_other"] as Int? ?? 0) == 1,
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            checkIn: CheckInCadence(cadence: ProactiveCadence(rawValue: row["checkin_cadence"] ?? "none") ?? .none,
                                    hour: row["checkin_hour"] ?? CheckInCadence.defaultHour,
                                    minute: row["checkin_minute"] ?? 0,
                                    weekday: row["checkin_weekday"]))
    }

    static func checkIn(from row: Row) -> GoalCheckIn {
        GoalCheckIn(
            id: row["id"],
            goalId: row["goal_id"],
            askedAt: Date(timeIntervalSince1970: row["asked_at"]),
            answeredAt: (row["answered_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            answer: (row["answer"] as String?).flatMap(CheckInAnswer.init(rawValue:)),
            note: row["note"] ?? "")
    }
}
