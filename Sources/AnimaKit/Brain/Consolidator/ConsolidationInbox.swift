// ConsolidationInbox.swift — la cola de candidatos (§5.4 etapa a). El AgentLoop
// encola en caliente los hechos declarados por el dueño; el Consolidator los
// procesa offline. Nunca se escribe directo al brain en un turno interactivo.

import Foundation
import GRDB

public final class ConsolidationInbox: Sendable {
    private let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// Encola un texto declarado por el dueño. Ignora vacíos.
    public func enqueue(sessionId: SessionID?, text: String, source: String = "turn") throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO consolidation_inbox (session_id, text, source, created_at, cycle, consolidated_at)
                VALUES (?,?,?,?,NULL,NULL)
                """, arguments: [sessionId, trimmed, source, now])
        }
    }

    public func pendingCount() throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM consolidation_inbox WHERE consolidated_at IS NULL") ?? 0
        }
    }
}
