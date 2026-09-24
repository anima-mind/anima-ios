// Telemetry.swift — observabilidad day-1 (§3, §7): usage por turno + tool calls
// + retries a GRDB. Alimenta la vista de costos reales en Settings desde Fase 0.

import Foundation
import GRDB

public final class Telemetry: Sendable {
    private let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// Registra un turno completo.
    public func record(sessionId: SessionID, turnClass: TurnClass, model: String,
                        usage: Usage, toolCalls: Int, retries: Int) throws {
        let now = Date().timeIntervalSince1970
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO turn_telemetry
                    (session_id, turn_class, model, input_tokens, output_tokens,
                     cache_read_tokens, cache_creation_tokens, tool_calls, retries, ts)
                    VALUES (?,?,?,?,?,?,?,?,?,?)
                    """,
                arguments: [
                    sessionId, turnClass.rawValue, model,
                    usage.inputTokens, usage.outputTokens,
                    usage.cacheReadInputTokens ?? 0, usage.cacheCreationInputTokens ?? 0,
                    toolCalls, retries, now,
                ])
        }
    }

    // MARK: - Agregados de costos

    public struct CostRow: Sendable, Equatable {
        public var model: String
        public var turnClass: String
        public var turns: Int
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheReadTokens: Int
        public var costUSD: Double
    }

    /// Costos agregados por (modelo, clase de turno).
    public func summary() throws -> [CostRow] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT model, turn_class,
                       COUNT(*) AS turns,
                       SUM(input_tokens) AS input_tokens,
                       SUM(output_tokens) AS output_tokens,
                       SUM(cache_read_tokens) AS cache_read_tokens
                FROM turn_telemetry
                GROUP BY model, turn_class
                ORDER BY model, turn_class
                """)
            return rows.map { row in
                let model: String = row["model"]
                let input: Int = row["input_tokens"] ?? 0
                let output: Int = row["output_tokens"] ?? 0
                let cacheRead: Int = row["cache_read_tokens"] ?? 0
                return CostRow(
                    model: model,
                    turnClass: row["turn_class"],
                    turns: row["turns"] ?? 0,
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: cacheRead,
                    costUSD: Pricing.cost(model: model, input: input, output: output, cacheRead: cacheRead))
            }
        }
    }

    public func totalCostUSD() throws -> Double {
        try summary().reduce(0) { $0 + $1.costUSD }
    }
}

/// Precios USD por millón de tokens (§7). Cache reads ~0.1× del input.
public enum Pricing {
    struct Rate { let input: Double; let output: Double }

    static func rate(for model: String) -> Rate {
        // Modelo local de Apple (§4.9): gratis, cero red.
        if model == OnDeviceProvider.modelName { return Rate(input: 0, output: 0) }
        if model.hasPrefix("claude-opus") { return Rate(input: 5, output: 25) }
        if model.hasPrefix("claude-sonnet") { return Rate(input: 3, output: 15) }
        if model.hasPrefix("claude-haiku") { return Rate(input: 1, output: 5) }
        return Rate(input: 5, output: 25)
    }

    static func cost(model: String, input: Int, output: Int, cacheRead: Int) -> Double {
        let r = rate(for: model)
        let uncachedInput = max(0, input - cacheRead)
        let million = 1_000_000.0
        return Double(uncachedInput) / million * r.input
            + Double(cacheRead) / million * (r.input * 0.1)
            + Double(output) / million * r.output
    }
}
