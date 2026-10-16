// ReengagementQuestionStore.swift — las preguntas que el sueño deja listas para
// los avisos por inactividad. Migración v19 congelada (SQL crudo, aditiva: un
// build viejo ignora la tabla). Una pregunta se entrega UNA vez (delivered_at);
// la tanda de cada noche retira las no usadas de la anterior (retired_at, nunca
// se borran: un aviso ya programado con una vieja sigue resolviendo su texto).

import Foundation
import GRDB

public enum ReengagementSchema {
    public static func register(_ m: inout DatabaseMigrator) {
        m.registerMigration("v19-reengagement-question") { db in
            try db.execute(sql: """
                CREATE TABLE reengagement_question (
                    id TEXT PRIMARY KEY,
                    text TEXT NOT NULL,
                    cycle INTEGER NOT NULL,
                    rank INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    delivered_at REAL NULL,
                    retired_at REAL NULL
                );
                """)
            try db.execute(sql: """
                CREATE INDEX idx_reengagement_question_open
                ON reengagement_question(delivered_at, retired_at, created_at);
                """)
        }
    }
}

public struct ReengagementQuestion: Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public var cycle: Int
    public var rank: Int
    public var createdAt: Date
    public var deliveredAt: Date?
    public var retiredAt: Date?
}

public struct ReengagementQuestionStore: Sendable {
    private let queue: DatabaseQueue
    private let now: @Sendable () -> Date
    /// No se vuelve a guardar una pregunta igual a una entregada en este lapso.
    public static let repeatWindow: TimeInterval = 30 * 24 * 3600

    public init(queue: DatabaseQueue, now: @escaping @Sendable () -> Date = { Date() }) {
        self.queue = queue
        self.now = now
    }

    /// La tanda de la noche: retira las no entregadas de antes y guarda las nuevas
    /// (sin repetir las entregadas en los últimos 30 días). Devuelve las guardadas.
    @discardableResult
    public func replace(with texts: [String], cycle: Int) throws -> [ReengagementQuestion] {
        let ts = now()
        return try queue.write { db in
            let recent = try String.fetchAll(db, sql: """
                SELECT text FROM reengagement_question WHERE delivered_at IS NOT NULL AND delivered_at > ?
                """, arguments: [ts.addingTimeInterval(-Self.repeatWindow).timeIntervalSince1970])
            var seen = Set(recent.map(ReengagementTextGuard.key))
            var kept: [ReengagementQuestion] = []
            for text in texts {
                let key = ReengagementTextGuard.key(text)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                kept.append(ReengagementQuestion(id: UUID().uuidString, text: text, cycle: cycle, rank: kept.count,
                                                 createdAt: ts))
            }
            guard !kept.isEmpty else { return [] }
            try db.execute(sql: """
                UPDATE reengagement_question SET retired_at=? WHERE delivered_at IS NULL AND retired_at IS NULL
                """, arguments: [ts.timeIntervalSince1970])
            for q in kept {
                try db.execute(sql: """
                    INSERT INTO reengagement_question (id, text, cycle, rank, created_at) VALUES (?,?,?,?,?)
                    """, arguments: [q.id, q.text, q.cycle, q.rank, ts.timeIntervalSince1970])
            }
            return kept
        }
    }

    /// Las siguientes sin usar: la tanda más reciente, en su orden.
    public func upcoming(limit: Int) -> [ReengagementQuestion] {
        (try? queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM reengagement_question WHERE delivered_at IS NULL AND retired_at IS NULL
                ORDER BY created_at DESC, rank ASC LIMIT ?
                """, arguments: [limit]).map(Self.question(from:))
        }) ?? []
    }

    public func question(id: String) -> ReengagementQuestion? {
        (try? queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM reengagement_question WHERE id=?", arguments: [id])
                .map(Self.question(from:))
        }) ?? nil
    }

    /// Entregada (la hora del aviso pasó o el dueño la abrió): jamás se reusa.
    public func markDelivered(id: String, at date: Date) {
        try? queue.write { db in
            try db.execute(sql: """
                UPDATE reengagement_question SET delivered_at=? WHERE id=? AND delivered_at IS NULL
                """, arguments: [date.timeIntervalSince1970, id])
        }
    }

    static func question(from row: Row) -> ReengagementQuestion {
        ReengagementQuestion(
            id: row["id"], text: row["text"], cycle: row["cycle"], rank: row["rank"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            deliveredAt: (row["delivered_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            retiredAt: (row["retired_at"] as Double?).map(Date.init(timeIntervalSince1970:)))
    }
}
