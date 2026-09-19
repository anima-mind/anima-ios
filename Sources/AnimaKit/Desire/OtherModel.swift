// OtherModel.swift — el modelo del deseo del dueño (§5.8). El Otro = Joshua. Actor
// sobre la DatabaseQueue compartida. Precedencia dura: stated > inferred >
// structural. Un goal inferred NUNCA motiva nada hasta que el dueño lo confirma:
// nace pending_confirmation y aparece en el MISMO inbox de Aprobaciones de Fase 3
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

    public init(id: String, statement: String, desiredState: ObservablePredicate,
                source: GoalSource, status: GoalStatus, priority: Int, evidence: String,
                confirmedByOther: Bool, createdAt: Date, updatedAt: Date) {
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

    public init(queue: DatabaseQueue, now: @escaping @Sendable () -> Date = { Date() }) {
        self.queue = queue
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
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
    }
}
