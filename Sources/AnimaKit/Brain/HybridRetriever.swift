// HybridRetriever.swift — retrieval híbrido (§5.3): FTS5 (BM25) + coseno sobre
// embeddings on-device, fusionados con Reciprocal Rank Fusion (k=60). Respeta la
// validez bi-temporal: nunca considera memorias invalidadas. Brute-force sobre
// los embeddings — a escala personal (<100k memorias) sobra (§5.3).

import Foundation
import GRDB

// No es Sendable: se usa solo dentro del actor Brain (actor-isolated), y sostiene
// un Embedder con caché mutable de NLEmbedding.
struct HybridRetriever {
    let queue: DatabaseQueue
    let embedder: Embedder

    static let rrfK = 60.0

    /// Fusión RRF de la pata léxica (BM25) y la semántica (coseno). Devuelve
    /// [(id, score)] ordenado desc, solo memorias vivas.
    func retrieve(text: String, limit: Int) throws -> [(id: String, score: Double)] {
        let keyword = try ftsSearch(text, limit: 50)
        let vector = try cosineScored(text, limit: 50).map(\.id)
        var score: [String: Double] = [:]
        for (rank, id) in keyword.enumerated() { score[id, default: 0] += 1.0 / (Self.rrfK + Double(rank + 1)) }
        for (rank, id) in vector.enumerated() { score[id, default: 0] += 1.0 / (Self.rrfK + Double(rank + 1)) }
        return score
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map { (id: $0.key, score: $0.value) }
    }

    // MARK: - Pata léxica (BM25, solo vivas)

    func ftsSearch(_ text: String, limit: Int) throws -> [String] {
        let match = Self.ftsQuery(text)
        guard !match.isEmpty else { return [] }
        return try queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT m.id FROM memory_fts f
                JOIN memory m ON m.rowid = f.rowid
                WHERE memory_fts MATCH ? AND m.invalidated_at IS NULL
                ORDER BY bm25(memory_fts) ASC
                LIMIT ?
                """, arguments: [match, limit])
        }
    }

    // MARK: - Pata semántica (coseno, solo vivas y mismo embedder_rev)

    func cosineScored(_ text: String, limit: Int) throws -> [(id: String, score: Double)] {
        let query = embedder.embed(text)
        let rows: [(String, [Float])] = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.memory_id AS id, e.vector AS vector FROM memory_embedding e
                JOIN memory m ON m.id = e.memory_id
                WHERE m.invalidated_at IS NULL AND e.embedder_rev = ?
                """, arguments: [query.rev]).map { row in
                let id: String = row["id"]
                let data: Data = row["vector"]
                return (id, [Float](floatData: data))
            }
        }
        return rows
            .map { (id: $0.0, score: Self.cosine(query.values, $0.1)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denom = sqrt(na) * sqrt(nb)
        return denom > 0 ? Double(dot / denom) : 0
    }

    /// Convierte texto libre en una query FTS5 MATCH: OR de tokens citados
    /// (las comillas evitan errores de sintaxis con caracteres reservados).
    static func ftsQuery(_ text: String) -> String {
        let tokens = Embedder.tokenize(text)
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
    }
}
