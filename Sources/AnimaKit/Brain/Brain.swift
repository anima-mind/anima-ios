// Brain.swift — memoria de largo plazo local (§5.3). Actor: el escritor único
// (el gate del Consolidator) sale gratis. Invalidación bi-temporal: NUNCA se
// borra una memoria, se marca invalidada con razón. La reconsolidación crea una
// fila nueva enlazada por revises_id (la vieja queda como historia).

import Foundation
import GRDB

public typealias MemoryID = String

public enum MemoryKind: String, Sendable, Codable, Equatable {
    case episodic, semantic, procedural, reflection
    case lesson   // Fase 3 (§5.6): lección destilada de un patrón de fallo del RealRegister.
}

/// Resultado de una recuperación con outcome, para el usage_log (§5.3).
public enum Outcome: String, Sendable, Codable, Equatable {
    case success, failure, contradicted, neutral
}

/// Candidato de memoria destilado por el Consolidator (§5.4 etapa b).
public struct MemoryCandidate: Sendable, Equatable, Codable {
    public var content: String
    public var kind: MemoryKind
    public var importance: Int          // 1-10
    public var eventAt: Date?
    public var source: String

    public init(content: String, kind: MemoryKind = .semantic, importance: Int = 5,
                eventAt: Date? = nil, source: String = "") {
        self.content = content
        self.kind = kind
        self.importance = max(1, min(10, importance))
        self.eventAt = eventAt
        self.source = source
    }
}

/// Directiva de escritura resuelta por el Consolidator (patrón Mem0).
public enum WriteDirective: Sendable, Equatable {
    case add(MemoryCandidate)
    case update(MemoryID, MemoryCandidate, reason: String)   // refina/reemplaza: invalida vieja + añade
    case invalidate(MemoryID, reason: String)                // contradicha por corrección explícita
    case noop                                                // duplicado
}

public enum WriteDecision: Sendable, Equatable {
    case added(MemoryID)
    case updated(new: MemoryID, previous: MemoryID)
    case invalidated(MemoryID)
    case noop
}

/// Revisión propuesta por la reconsolidación (§5.4 etapa d).
public struct Revision: Sendable, Equatable {
    public var content: String
    public var importance: Int
    public var reason: String
    public init(content: String, importance: Int, reason: String) {
        self.content = content
        self.importance = max(1, min(10, importance))
        self.reason = reason
    }
}

/// Query de recuperación de un turno. `turnRef` alimenta el usage_log.
public struct MemoryQuery: Sendable, Equatable {
    public var text: String
    public var turnRef: String
    public var limit: Int
    public init(text: String, turnRef: String, limit: Int = 8) {
        self.text = text
        self.turnRef = turnRef
        self.limit = limit
    }
}

/// Memoria activada para el contexto del turno (§5.1 posición 6).
public struct ActivatedMemory: Sendable, Equatable {
    public var id: MemoryID
    public var content: String
    public var kind: MemoryKind
    public var confidence: Double     // importance / 10
    public var score: Double          // score RRF
}

/// Fila completa de memoria (para el browser y el Consolidator).
public struct MemoryRecord: Sendable, Equatable, Identifiable {
    public var id: MemoryID
    public var kind: MemoryKind
    public var content: String
    public var importance: Int
    public var source: String
    public var createdAt: Date
    public var eventAt: Date?
    public var invalidatedAt: Date?
    public var invalidationReason: String?
    public var revisesId: MemoryID?
    public var consolidationCycle: Int

    public var isValid: Bool { invalidatedAt == nil }
    public var confidence: Double { Double(importance) / 10 }

    init(row: Row) {
        self.id = row["id"]
        self.kind = MemoryKind(rawValue: row["kind"]) ?? .semantic
        self.content = row["content"]
        self.importance = row["importance"]
        self.source = row["source"]
        self.createdAt = Date(timeIntervalSince1970: row["created_at"])
        self.eventAt = (row["event_at"] as Double?).map { Date(timeIntervalSince1970: $0) }
        self.invalidatedAt = (row["invalidated_at"] as Double?).map { Date(timeIntervalSince1970: $0) }
        self.invalidationReason = row["invalidation_reason"]
        self.revisesId = row["revises_id"]
        self.consolidationCycle = row["consolidation_cycle"]
    }
}

public actor Brain {
    private let queue: DatabaseQueue
    private let embedder: Embedder
    private let retriever: HybridRetriever

    public init(queue: DatabaseQueue, embedder: Embedder = Embedder()) {
        self.queue = queue
        self.embedder = embedder
        self.retriever = HybridRetriever(queue: queue, embedder: embedder)
    }

    // MARK: - Escritura (los 4 caminos)

    @discardableResult
    public func write(_ directive: WriteDirective, cycle: Int = 0) throws -> WriteDecision {
        switch directive {
        case .add(let candidate):
            return .added(try add(candidate, cycle: cycle))
        case .update(let id, let candidate, let reason):
            let new = try reconsolidate(id: id,
                                        revision: Revision(content: candidate.content,
                                                           importance: candidate.importance,
                                                           reason: reason),
                                        cycle: cycle)
            return .updated(new: new, previous: id)
        case .invalidate(let id, let reason):
            try invalidate(id: id, reason: reason)
            return .invalidated(id)
        case .noop:
            return .noop
        }
    }

    @discardableResult
    public func add(_ candidate: MemoryCandidate, cycle: Int = 0, revises: MemoryID? = nil) throws -> MemoryID {
        let id = UUID().uuidString
        let now = Date().timeIntervalSince1970
        let vector = embedder.embed(candidate.content)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO memory
                    (id, kind, content, importance, source, created_at, event_at,
                     invalidated_at, invalidation_reason, revises_id, consolidation_cycle)
                VALUES (?,?,?,?,?,?,?,NULL,NULL,?,?)
                """, arguments: [id, candidate.kind.rawValue, candidate.content, candidate.importance,
                                 candidate.source, now, candidate.eventAt?.timeIntervalSince1970,
                                 revises, cycle])
            try db.execute(sql: """
                INSERT INTO memory_embedding (memory_id, vector, dim, embedder_rev)
                VALUES (?,?,?,?)
                """, arguments: [id, vector.values.floatData, vector.values.count, vector.rev])
        }
        return id
    }

    /// Bi-temporal: marca invalidada con razón. Jamás DELETE. Idempotente (solo
    /// afecta filas vivas).
    public func invalidate(id: MemoryID, reason: String) throws {
        let now = Date().timeIntervalSince1970
        try queue.write { db in
            try db.execute(sql: """
                UPDATE memory SET invalidated_at=?, invalidation_reason=?
                WHERE id=? AND invalidated_at IS NULL
                """, arguments: [now, reason, id])
        }
    }

    /// Reconsolidación (§5.4 etapa d): invalida la vieja y añade una fila revisada
    /// enlazada por revises_id. Devuelve el id de la fila nueva.
    @discardableResult
    public func reconsolidate(id: MemoryID, revision: Revision, cycle: Int = 0) throws -> MemoryID {
        guard let old = try record(id) else { return id }
        try invalidate(id: id, reason: revision.reason)
        let candidate = MemoryCandidate(content: revision.content, kind: old.kind,
                                        importance: revision.importance, eventAt: old.eventAt,
                                        source: old.source)
        let new = try add(candidate, cycle: cycle, revises: id)
        try link(src: new, dst: id, relation: "revises")
        return new
    }

    public func link(src: MemoryID, dst: MemoryID, relation: String) throws {
        try queue.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO memory_link (src, dst, relation) VALUES (?,?,?)",
                           arguments: [src, dst, relation])
        }
    }

    // MARK: - Recuperación

    /// Recupera memorias para el contexto de un turno y loguea cada recuperación
    /// en usage_log (§5.3). Nunca retorna invalidadas (lo garantiza el retriever).
    @discardableResult
    public func retrieve(_ query: MemoryQuery) throws -> [ActivatedMemory] {
        let fused = try retriever.retrieve(text: query.text, limit: query.limit)
        let activated: [ActivatedMemory] = try queue.read { db in
            try fused.compactMap { pair in
                guard let record = try Self.fetchRecord(db, id: pair.id), record.isValid else { return nil }
                return ActivatedMemory(id: record.id, content: record.content, kind: record.kind,
                                       confidence: record.confidence, score: pair.score)
            }
        }
        if !activated.isEmpty {
            let now = Date().timeIntervalSince1970
            try queue.write { db in
                for memory in activated {
                    try db.execute(sql: "INSERT INTO usage_log (turn_ref, memory_id, outcome, ts) VALUES (?,?,?,?)",
                                   arguments: [query.turnRef, memory.id, Outcome.neutral.rawValue, now])
                }
            }
        }
        return activated
    }

    /// Memorias vivas semánticamente similares por encima de un umbral de coseno
    /// (para que la etapa de escritura decida ADD/UPDATE/INVALIDATE/NOOP).
    public func similar(to text: String, limit: Int = 5, threshold: Double = 0.6) throws -> [MemoryRecord] {
        let scored = try retriever.cosineScored(text, limit: limit).filter { $0.score >= threshold }
        return try queue.read { db in
            try scored.compactMap { try Self.fetchRecord(db, id: $0.id) }.filter { $0.isValid }
        }
    }

    // MARK: - usage_log

    public func usageLog(memoryId: MemoryID, sessionId: SessionID, outcome: Outcome = .success) throws {
        let now = Date().timeIntervalSince1970
        try queue.write { db in
            try db.execute(sql: "INSERT INTO usage_log (turn_ref, memory_id, outcome, ts) VALUES (?,?,?,?)",
                           arguments: [sessionId, memoryId, outcome.rawValue, now])
        }
    }

    /// Memorias vivas recuperadas ≥ minCount veces desde `since` (reconsolidación).
    public func frequentlyUsed(since: Date, minCount: Int = 2) throws -> [MemoryID] {
        try queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT u.memory_id FROM usage_log u
                JOIN memory m ON m.id = u.memory_id
                WHERE u.ts >= ? AND m.invalidated_at IS NULL
                GROUP BY u.memory_id HAVING COUNT(*) >= ?
                """, arguments: [since.timeIntervalSince1970, minCount])
        }
    }

    /// Memorias vivas marcadas como contradicha desde `since`.
    public func contradicted(since: Date) throws -> [MemoryID] {
        try queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT u.memory_id FROM usage_log u
                JOIN memory m ON m.id = u.memory_id
                WHERE u.ts >= ? AND u.outcome = 'contradicted' AND m.invalidated_at IS NULL
                """, arguments: [since.timeIntervalSince1970])
        }
    }

    // MARK: - Lectura para el browser

    public func record(_ id: MemoryID) throws -> MemoryRecord? {
        try queue.read { db in try Self.fetchRecord(db, id: id) }
    }

    /// Lista para el MemoryBrowserView: filtro por texto, más recientes primero.
    public func browse(filter: String? = nil, limit: Int = 200) throws -> [MemoryRecord] {
        try queue.read { db in
            let rows: [Row]
            if let filter, !filter.trimmingCharacters(in: .whitespaces).isEmpty {
                rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM memory WHERE content LIKE ? ORDER BY created_at DESC LIMIT ?
                    """, arguments: ["%\(filter)%", limit])
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM memory ORDER BY created_at DESC LIMIT ?",
                                        arguments: [limit])
            }
            return rows.map(MemoryRecord.init(row:))
        }
    }

    public func lastUsed(_ id: MemoryID) throws -> Date? {
        try queue.read { db in
            (try Double.fetchOne(db, sql: "SELECT MAX(ts) FROM usage_log WHERE memory_id=?", arguments: [id]))
                .map { Date(timeIntervalSince1970: $0) }
        }
    }

    /// Cadena de reconsolidación: la memoria, sus predecesoras (revises_id hacia
    /// atrás) y sus sucesoras (quién la revisa), de la más vieja a la más nueva.
    public func revisionChain(_ id: MemoryID) throws -> [MemoryRecord] {
        try queue.read { db in
            var chain: [MemoryRecord] = []
            // Hacia atrás: predecesoras.
            var cursor: MemoryID? = id
            var backward: [MemoryRecord] = []
            while let current = cursor, let record = try Self.fetchRecord(db, id: current) {
                backward.append(record)
                cursor = record.revisesId
                if backward.count > 64 { break }
            }
            chain = backward.reversed()
            // Hacia adelante: sucesoras.
            var forwardCursor: MemoryID? = id
            while let current = forwardCursor {
                guard let next = try Row.fetchOne(db, sql: "SELECT * FROM memory WHERE revises_id=? ORDER BY created_at ASC LIMIT 1",
                                                  arguments: [current]) else { break }
                let record = MemoryRecord(row: next)
                chain.append(record)
                forwardCursor = record.id
                if chain.count > 128 { break }
            }
            return chain
        }
    }

    static func fetchRecord(_ db: Database, id: String) throws -> MemoryRecord? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM memory WHERE id=?", arguments: [id]) else {
            return nil
        }
        return MemoryRecord(row: row)
    }
}
