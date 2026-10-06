import Foundation
import Testing
@testable import AnimaKit

@Suite struct TelemetryTests {

    @Test func accumulatesUsagePerTurn() throws {
        let queue = try AnimaDatabase.temporary()
        let telemetry = Telemetry(queue: queue)
        let sid = "s1"

        try telemetry.record(sessionId: sid, turnClass: .interactive, model: "claude-opus-4-8",
                             usage: Usage(inputTokens: 1000, outputTokens: 500,
                                          cacheReadInputTokens: 200), toolCalls: 1, retries: 0)
        try telemetry.record(sessionId: sid, turnClass: .interactive, model: "claude-opus-4-8",
                             usage: Usage(inputTokens: 2000, outputTokens: 800,
                                          cacheReadInputTokens: 0), toolCalls: 0, retries: 1)

        let summary = try telemetry.summary()
        let opus = try #require(summary.first { $0.model == "claude-opus-4-8" })
        #expect(opus.turns == 2)
        #expect(opus.inputTokens == 3000)
        #expect(opus.outputTokens == 1300)
        #expect(opus.cacheReadTokens == 200)
        #expect(opus.costUSD > 0)
    }

    @Test func totalCostSumsRows() throws {
        let queue = try AnimaDatabase.temporary()
        let telemetry = Telemetry(queue: queue)
        try telemetry.record(sessionId: "s1", turnClass: .interactive, model: "claude-opus-4-8",
                             usage: Usage(inputTokens: 1_000_000, outputTokens: 0), toolCalls: 0, retries: 0)
        try telemetry.record(sessionId: "s1", turnClass: .consolidation, model: "claude-haiku-4-5",
                             usage: Usage(inputTokens: 1_000_000, outputTokens: 0), toolCalls: 0, retries: 0)
        // 1M input opus = $5, 1M input haiku = $1 → total $6.
        #expect(abs(try telemetry.totalCostUSD() - 6.0) < 1e-6)
    }

    @Test func cacheReadsAreCheaperThanFullInput() {
        // 1M input a $5 full vs cache read a ~$0.5.
        let full = Pricing.cost(model: "claude-opus-4-8", input: 1_000_000, output: 0, cacheRead: 0)
        let cached = Pricing.cost(model: "claude-opus-4-8", input: 1_000_000, output: 0, cacheRead: 1_000_000)
        #expect(abs(full - 5.0) < 1e-6)
        #expect(abs(cached - 0.5) < 1e-6)
    }
}


@Suite struct PricingTests {
    @Test func bundledDefaultsCoverAllDialModels() {
        defer { Pricing.resetForTests() }
        #expect(Pricing.rate(for: "gpt-5.2").input == 1.75)
        #expect(Pricing.rate(for: "gpt-5-mini").output == 2)
        #expect(Pricing.rate(for: "gemini-3.1-pro-preview").output == 12)  // prefijo cubre -preview
        #expect(Pricing.rate(for: "gemini-3.8-flash").input == 0.75)
        #expect(Pricing.rate(for: "claude-haiku-4-5").input == 1)
        #expect(Pricing.rate(for: "modelo-desconocido").output == 25)  // caro, jamás barato
    }

    @Test func remoteOverrideWinsAndLongestPrefixFirst() throws {
        defer { Pricing.resetForTests() }
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"gpt-5": {"in": 9, "out": 90}, "gpt-5-mini": {"in": 0.1, "out": 1}, "rota": "ignorada"}
        """.utf8))
        Pricing.load(json)
        #expect(Pricing.rate(for: "gpt-5-mini-2027").input == 0.1)  // el largo gana
        #expect(Pricing.rate(for: "gpt-5.9").input == 9)
        #expect(Pricing.rate(for: "system_language_model").input == 0)  // el local SIEMPRE es gratis, tabla aparte
    }

    @Test func pricingKeyExtractedFromProviderConfig() {
        let data = Data(#"{"anthropic":{"api":{"base_url":"https://x.com"},"routes":{}},"pricing":{"a":{"in":1,"out":2}}}"#.utf8)
        #expect(ProviderConfigParser.pricing(data) != nil)
        // y parse() sigue ignorando la clave sin crashear
        #expect((try? ProviderConfigParser.parse(data))?.count == 1)
    }
}

/// Campo batch 5 #2: "se repite mucho system_language_model". Causa: la vista
/// iteraba las filas (modelo, clase) con `id: \.model` — ids duplicados → SwiftUI
/// repetía la primera fila. Ahora: una fila por modelo, normalizado al escribir
/// y al leer, con nombre para humanos y el desglose por clase.
@Suite struct ModelCostsTests {
    @Test func oneRowPerModelEvenWithDirtyIdsAndSeveralClasses() throws {
        let queue = try AnimaDatabase.temporary()
        let telemetry = Telemetry(queue: queue)
        let usage = Usage(inputTokens: 10, outputTokens: 10)
        for (model, turnClass) in [("system_language_model", TurnClass.interactive),
                                   ("system_language_model", .consolidation),
                                   (" System_Language_Model\n", .distill),
                                   ("system_language_model", .desirePulse)] {
            try telemetry.record(sessionId: "s", turnClass: turnClass, model: model, usage: usage,
                                 toolCalls: 0, retries: 0)
        }
        // Una fila vieja sin normalizar (escrita antes del fix) también se agrupa.
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO turn_telemetry (session_id, turn_class, model, input_tokens, output_tokens,
                    cache_read_tokens, cache_creation_tokens, tool_calls, retries, ts)
                VALUES ('s', 'interactive', 'SYSTEM_LANGUAGE_MODEL ', 1, 1, 0, 0, 0, 0, 0)
                """)
        }
        let summary = try telemetry.summary()
        #expect(Set(summary.map(\.model)) == ["system_language_model"])
        #expect(summary.count == 4)                          // (modelo, clase): por eso se repetía
        let rows = Telemetry.byModel(summary)
        #expect(rows.count == 1)
        #expect(Set(rows.map(\.id)).count == rows.count)     // ids únicos para el ForEach
        #expect(rows[0].displayName == "Modelo local (Apple)")
        #expect(rows[0].breakdown == "Conversación 2 · Sueño 2 · Pulso 1")
        #expect(rows[0].turns == 5)
    }

    @Test func friendlyNames() {
        #expect(ModelNames.friendly("claude-opus-4-8") == "Claude Opus 4.8")
        #expect(ModelNames.friendly("claude-haiku-4-5") == "Claude Haiku 4.5")
        #expect(ModelNames.friendly("claude-sonnet-4-5-20250929") == "Claude Sonnet 4.5")
        #expect(ModelNames.friendly("claude-opus") == "claude-opus")
        #expect(ModelNames.friendly("claude-x-latest") == "Claude X")
        #expect(ModelNames.friendly("gpt-5.2") == "GPT-5.2")
        #expect(ModelNames.friendly("gpt-5-mini") == "GPT-5 mini")
        #expect(ModelNames.friendly("gpt") == "gpt")
        #expect(ModelNames.friendly("gemini-3.1-pro-preview") == "Gemini 3.1 Pro (preview)")
        #expect(ModelNames.friendly("gemini") == "gemini")
        #expect(ModelNames.friendly("mistral-large") == "mistral-large")
        #expect(ModelNames.friendly("") == "")
        #expect(ModelNames.turnClassLabel("restructure") == "Replanteo")
        #expect(ModelNames.turnClassLabel("interactiveHard") == "Conversación")
        #expect(ModelNames.turnClassLabel("otra") == "otra")
    }

    @Test func rowsSortByCostThenName() throws {
        let rows = Telemetry.byModel([
            .init(model: "claude-haiku-4-5", turnClass: "consolidation", turns: 1, inputTokens: 0, outputTokens: 0,
                  cacheReadTokens: 0, costUSD: 0.5),
            .init(model: "claude-opus-4-8", turnClass: "interactive", turns: 3, inputTokens: 0, outputTokens: 0,
                  cacheReadTokens: 0, costUSD: 2),
            .init(model: "a-model", turnClass: "interactive", turns: 1, inputTokens: 0, outputTokens: 0,
                  cacheReadTokens: 0, costUSD: 0.5),
        ])
        #expect(rows.map(\.model) == ["claude-opus-4-8", "a-model", "claude-haiku-4-5"])
    }
}
