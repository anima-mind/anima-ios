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

    // MARK: - Skills (match / inyección / outcome por turno)

    /// Una fila por turno con el SkillEngine cableado — también sin match
    /// (skillName nil): el eval futuro compara turnos con y sin skill.
    public struct SkillTurnRow: Sendable, Equatable {
        public var sessionId: SessionID
        public var skillName: String?
        public var score: Double?
        public var injectedChars: Int
        public var truncated: Bool
        public var outcome: String          // SkillOutcome.rawValue o "none"
        public var endReason: String        // endTurn / stopped:loopDetected / error …
        public var skillToolCalls: Int
        public var skillToolErrors: Int
        /// El SkillRunner corrió (skill automatizado + match ≥ umbral alto).
        public var automatized: Bool
        /// Pasos aferentes que el runner ejecutó sin LLM.
        public var automatedSteps: Int
        /// AutomationAbort.rawValue si abortó; nil si completó o no corrió.
        public var automationAbort: String?

        public init(sessionId: SessionID, skillName: String?, score: Double?, injectedChars: Int,
                    truncated: Bool, outcome: String, endReason: String,
                    skillToolCalls: Int, skillToolErrors: Int,
                    automatized: Bool = false, automatedSteps: Int = 0, automationAbort: String? = nil) {
            self.sessionId = sessionId
            self.skillName = skillName
            self.score = score
            self.injectedChars = injectedChars
            self.truncated = truncated
            self.outcome = outcome
            self.endReason = endReason
            self.skillToolCalls = skillToolCalls
            self.skillToolErrors = skillToolErrors
            self.automatized = automatized
            self.automatedSteps = automatedSteps
            self.automationAbort = automationAbort
        }
    }

    public func recordSkillTurn(_ row: SkillTurnRow) throws {
        let now = Date().timeIntervalSince1970
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO skill_turn_telemetry
                (session_id, skill_name, score, injected_chars, truncated, outcome, end_reason,
                 skill_tool_calls, skill_tool_errors, automatized, automated_steps, automation_abort, ts)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [row.sessionId, row.skillName, row.score, row.injectedChars,
                                 row.truncated ? 1 : 0, row.outcome, row.endReason,
                                 row.skillToolCalls, row.skillToolErrors,
                                 row.automatized ? 1 : 0, row.automatedSteps, row.automationAbort, now])
        }
    }

    public func skillTurns() throws -> [SkillTurnRow] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM skill_turn_telemetry ORDER BY id").map {
                SkillTurnRow(sessionId: $0["session_id"], skillName: $0["skill_name"], score: $0["score"],
                             injectedChars: $0["injected_chars"], truncated: ($0["truncated"] as Int) == 1,
                             outcome: $0["outcome"], endReason: $0["end_reason"],
                             skillToolCalls: $0["skill_tool_calls"], skillToolErrors: $0["skill_tool_errors"],
                             automatized: ($0["automatized"] as Int) == 1, automatedSteps: $0["automated_steps"],
                             automationAbort: $0["automation_abort"])
            }
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
    public struct Rate: Sendable, Equatable {
        public let input: Double
        public let output: Double
        public init(input: Double, output: Double) { self.input = input; self.output = output }
    }

    /// Tarifas por prefijo de modelo (USD por MTok). Los precios ROTAN igual que
    /// los model ids: la tabla se sobreescribe desde Remote Config (param
    /// `model_pricing`, clave "pricing" dentro de provider_config); esto es solo
    /// el fallback bundled. Verificados 2026-09-25 contra pricing oficial.
    nonisolated(unsafe) private static var table: [(prefix: String, rate: Rate)] = defaults
    private static let defaults: [(prefix: String, rate: Rate)] = [
        ("claude-opus", Rate(input: 5, output: 25)),
        ("claude-sonnet", Rate(input: 3, output: 15)),
        ("claude-haiku", Rate(input: 1, output: 5)),
        ("gpt-5.2", Rate(input: 1.75, output: 14)),
        ("gpt-5-mini", Rate(input: 0.25, output: 2)),
        ("gemini-3.1-pro", Rate(input: 2, output: 12)),
        // Promo hasta 2026-12-31 (luego 1.50/7.50) — razón de que viva en RC.
        ("gemini-3.8-flash", Rate(input: 0.75, output: 3.75)),
    ]

    /// Sobreescribe la tabla desde config remota: {"<prefijo>": {"in": x, "out": y}}.
    /// Claves/formas desconocidas se ignoran (forward-compatible, como todo RC).
    public static func load(_ json: JSONValue) {
        guard case .object(let entries) = json else { return }
        var parsed: [(String, Rate)] = []
        for (prefix, value) in entries {
            guard case .object(let o) = value,
                  let i = Self.number(o["in"]), let out = Self.number(o["out"]) else { continue }
            parsed.append((prefix, Rate(input: i, output: out)))
        }
        // Prefijos más largos primero: "gpt-5-mini" gana sobre "gpt-5".
        if !parsed.isEmpty { table = parsed.sorted { $0.0.count > $1.0.count } }
    }

    private static func number(_ v: JSONValue?) -> Double? {
        switch v {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    static func resetForTests() { table = defaults }

    static func rate(for model: String) -> Rate {
        // Modelo local de Apple (§4.9): gratis, cero red.
        if model == OnDeviceProvider.modelName { return Rate(input: 0, output: 0) }
        if let hit = table.first(where: { model.hasPrefix($0.prefix) }) { return hit.rate }
        return Rate(input: 5, output: 25)  // desconocido: asumir caro, jamás barato
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
