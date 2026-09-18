// Recovery.swift — clean-shutdown marker y resume (§5.2, invariante de Hermes
// adaptado al lifecycle iOS). En scenePhase .background se marca clean_shutdown=1;
// al lanzar, si la sesión activa tiene clean_shutdown=0 y last_event_at < 120s,
// se reanuda automáticamente (la app fue matada por jetsam a mitad de turno).
// Si restart_count >= 3 en la misma sesión, se suspende el resume y se abre una fresca.

import Foundation
import GRDB

public struct Recovery: Sendable {
    private let queue: DatabaseQueue
    private let store: SymbolicStore

    /// Ventana de resume: la app matada a mitad de turno reanuda si el último
    /// evento es reciente (objetivo <120s).
    public let resumeWindow: TimeInterval
    /// Tope de reintentos por sesión (session files corruptos → sesión fresca).
    public let maxRestarts: Int

    public init(queue: DatabaseQueue, store: SymbolicStore,
                resumeWindow: TimeInterval = 120, maxRestarts: Int = 3) {
        self.queue = queue
        self.store = store
        self.resumeWindow = resumeWindow
        self.maxRestarts = maxRestarts
    }

    public enum Decision: Sendable, Equatable {
        case resume(SessionID)
        case fresh
    }

    /// Decide al lanzar: reanudar la última sesión sucia y reciente, o abrir una fresca.
    /// Si reanuda, incrementa restart_count (para topar en maxRestarts).
    public func decide(now: Date = Date()) throws -> Decision {
        let candidate: SessionState? = try queue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM session WHERE clean_shutdown = 0 ORDER BY started_at DESC LIMIT 1")
            else { return nil }
            return SymbolicStore.state(from: row)
        }

        guard let session = candidate, let last = session.lastEventAt else {
            return .fresh
        }
        guard session.restartCount < maxRestarts else { return .fresh }
        guard now.timeIntervalSince(last) < resumeWindow else { return .fresh }

        try store.incrementRestartCount(session.id)
        return .resume(session.id)
    }
}
