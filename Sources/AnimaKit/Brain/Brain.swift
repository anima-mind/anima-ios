// Brain.swift — memoria de largo plazo local (§5.3). Actor: el escritor único
// (el gate del Consolidator) sale gratis. Invalidación bi-temporal: NUNCA se
// borra una memoria, se marca invalidada con razón. La reconsolidación crea una
// fila nueva enlazada por revises_id (la vieja queda como historia). El dueño
// puede restaurar una invalidada (owner_restored_at): su decisión gana al sueño.

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

extension WriteDirective {
    /// La memoria existente que la directiva invalida (UPDATE o INVALIDATE).
    var target: MemoryID? {
        switch self {
        case .update(let id, _, _), .invalidate(let id, _): return id
        case .add, .noop: return nil
        }
    }
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
    public var purgedAt: Date?
    /// Última vez que el dueño la restauró: el sueño no la vuelve a invalidar.
    public var ownerRestoredAt: Date?
    /// Decisiones del dueño sobre esta versión, de la más vieja a la más nueva.
    public var events: [MemoryEvent] = []

    public var isValid: Bool { invalidatedAt == nil }
    public var isPurged: Bool { purgedAt != nil }
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
        self.purgedAt = (row["purged_at"] as Double?).map { Date(timeIntervalSince1970: $0) }
        self.ownerRestoredAt = (row["owner_restored_at"] as Double?).map { Date(timeIntervalSince1970: $0) }
    }
}

/// Evento del historial de una versión (memory_event).
public struct MemoryEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case ownerRestored = "owner_restored"
    }
    public var kind: Kind
    public var detail: String?
    public var at: Date
}

/// Resultado de restaurar una memoria invalidada.
public enum RestoreOutcome: Sendable, Equatable {
    /// Vuelve a estar vigente; no había otra versión vigente en su cadena.
    case restored(MemoryID)
    /// Vuelve a estar vigente y la versión que la reemplazaba quedó invalidada.
    case replaced(restored: MemoryID, invalidated: [MemoryID])
    /// No existe, ya está vigente o fue eliminada: nada cambia.
    case unchanged
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
                    SELECT * FROM memory WHERE content LIKE ? AND purged_at IS NULL ORDER BY created_at DESC LIMIT ?
                    """, arguments: ["%\(filter)%", limit])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM memory WHERE purged_at IS NULL ORDER BY created_at DESC LIMIT ?
                    """, arguments: [limit])
            }
            return rows.map(MemoryRecord.init(row:))
        }
    }

    /// "Vaciar invalidadas": marca `purged_at` en las YA invalidadas (las vivas
    /// jamás se tocan). Siguen en la base; desaparecen de la UI. Devuelve cuántas.
    @discardableResult
    public func purgeInvalidated(at date: Date = Date()) throws -> Int {
        try queue.write { db in try Self.purge(db, id: nil, at: date) }
    }

    /// "Eliminar" UNA invalidada: lo mismo que "Vaciar invalidadas", solo para
    /// esa fila. La fila queda (sus enlaces revises_id sostienen la cadena de la
    /// versión vigente); sale de la lista y del historial. Una vigente no se toca.
    @discardableResult
    public func purge(id: MemoryID, at date: Date = Date()) throws -> Bool {
        try queue.write { db in try Self.purge(db, id: id, at: date) > 0 }
    }

    private static func purge(_ db: Database, id: MemoryID?, at date: Date) throws -> Int {
        var sql = "UPDATE memory SET purged_at=? WHERE invalidated_at IS NOT NULL AND purged_at IS NULL"
        var arguments: StatementArguments = [date.timeIntervalSince1970]
        if let id {
            sql += " AND id=?"
            arguments += [id]
        }
        try db.execute(sql: sql, arguments: arguments)
        return db.changesCount
    }

    public static let ownerReplacedReason = "reemplazada por el dueño"

    /// El dueño restaura una invalidada: vuelve a estar vigente (FTS y
    /// embeddings siguen ahí, así que la recuperación la encuentra de nuevo) con
    /// `owner_restored_at`. Si otra versión de su cadena estaba vigente, esa
    /// queda invalidada con "reemplazada por el dueño": nunca dos vigentes.
    @discardableResult
    public func restore(id: MemoryID, at date: Date = Date()) throws -> RestoreOutcome {
        try queue.write { db in
            guard let record = try Self.fetchRecord(db, id: id), !record.isValid, !record.isPurged else {
                return .unchanged
            }
            let ts = date.timeIntervalSince1970
            let others = try Self.chainRecords(db, id: id).filter { $0.id != id && $0.isValid }.map(\.id)
            for other in others {
                try db.execute(sql: """
                    UPDATE memory SET invalidated_at=?, invalidation_reason=?
                    WHERE id=? AND invalidated_at IS NULL
                    """, arguments: [ts, Self.ownerReplacedReason, other])
            }
            try db.execute(sql: """
                UPDATE memory SET invalidated_at=NULL, invalidation_reason=NULL, owner_restored_at=?
                WHERE id=?
                """, arguments: [ts, id])
            try db.execute(sql: "INSERT INTO memory_event (memory_id, kind, detail, ts) VALUES (?,?,?,?)",
                           arguments: [id, MemoryEvent.Kind.ownerRestored.rawValue, record.invalidationReason, ts])
            return others.isEmpty ? .restored(id) : .replaced(restored: id, invalidated: others)
        }
    }

    public func lastUsed(_ id: MemoryID) throws -> Date? {
        try queue.read { db in
            (try Double.fetchOne(db, sql: "SELECT MAX(ts) FROM usage_log WHERE memory_id=?", arguments: [id]))
                .map { Date(timeIntervalSince1970: $0) }
        }
    }

    /// Cadena de reconsolidación: todas las versiones enlazadas por revises_id
    /// (en ambos sentidos, también las ramas que deja restaurar una versión
    /// vieja), de la más vieja a la más nueva, con sus eventos. Las eliminadas
    /// sostienen la cadena pero no se muestran.
    public func revisionChain(_ id: MemoryID) throws -> [MemoryRecord] {
        try queue.read { db in
            try Self.chainRecords(db, id: id).filter { !$0.isPurged }.map { record in
                var record = record
                record.events = try Self.events(db, id: record.id)
                return record
            }
        }
    }

    static func chainRecords(_ db: Database, id: MemoryID) throws -> [MemoryRecord] {
        guard try Self.fetchRecord(db, id: id) != nil else { return [] }
        var seen: Set<MemoryID> = [id]
        var pending: [MemoryID] = [id]
        while let current = pending.popLast(), seen.count <= 128 {
            let neighbors = try String.fetchAll(db, sql: """
                SELECT revises_id FROM memory WHERE id=? AND revises_id IS NOT NULL
                UNION SELECT id FROM memory WHERE revises_id=?
                """, arguments: [current, current])
            for neighbor in neighbors where !seen.contains(neighbor) {
                seen.insert(neighbor)
                pending.append(neighbor)
            }
        }
        let placeholders = Array(repeating: "?", count: seen.count).joined(separator: ",")
        return try Row.fetchAll(db, sql: "SELECT * FROM memory WHERE id IN (\(placeholders)) ORDER BY created_at, rowid",
                                arguments: StatementArguments(Array(seen)))
            .map(MemoryRecord.init(row:))
    }

    static func events(_ db: Database, id: MemoryID) throws -> [MemoryEvent] {
        try Row.fetchAll(db, sql: "SELECT kind, detail, ts FROM memory_event WHERE memory_id=? ORDER BY ts, id",
                         arguments: [id]).compactMap { row in
            guard let kind = MemoryEvent.Kind(rawValue: row["kind"]) else { return nil }
            return MemoryEvent(kind: kind, detail: row["detail"], at: Date(timeIntervalSince1970: row["ts"]))
        }
    }

    static func fetchRecord(_ db: Database, id: String) throws -> MemoryRecord? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM memory WHERE id=?", arguments: [id]) else {
            return nil
        }
        return MemoryRecord(row: row)
    }
}
