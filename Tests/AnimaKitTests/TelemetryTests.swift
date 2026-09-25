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
