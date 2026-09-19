import Foundation
import Testing
@testable import AnimaKit

@Suite struct PressureReliefTests {

    /// La escalera del §5.1: >0.7 clear mecánico, >0.85 + compaction.
    @Test func planEscalatesByPressure() {
        #expect(PressureRelief.plan(pressure: 0.5) == ReliefControls())
        #expect(PressureRelief.plan(pressure: 0.71) == ReliefControls(clearStaleToolResults: true))
        #expect(PressureRelief.plan(pressure: 0.9) == ReliefControls(clearStaleToolResults: true, compact: true))
    }

    /// relieve(.compact) marca el control; consumeRelief lo entrega y lo limpia.
    @Test func relieveMarksAndConsumeClears() async throws {
        let store = SymbolicStore(queue: try AnimaDatabase.temporary())
        let wm = WorkingMemory(store: store)
        _ = await wm.relieve(.compact)
        let first = await wm.consumeRelief()
        #expect(first.compact)
        let second = await wm.consumeRelief()
        #expect(!second.compact)   // ya consumido (presión sigue baja)
    }

    /// evictToBrain es hook de Fase 2: no marca controles de request.
    @Test func evictToBrainIsNoopControl() async throws {
        let store = SymbolicStore(queue: try AnimaDatabase.temporary())
        let wm = WorkingMemory(store: store)
        let controls = await wm.relieve(.evictToBrain)
        #expect(!controls.isActive)
    }

    /// El request de compaction lleva la beta (header) Y la directiva en el body.
    @Test func compactionRequestCarriesBetaAndDirective() throws {
        var opts = try TestConfig.callOpts(authMode: .apiKey)
        opts.relief = ReliefControls(clearStaleToolResults: true, compact: true)
        let req = try ClaudeRequestBuilder.build(
            context: AssembledContext(messages: [.user("hola")]),
            tools: [], opts: opts)

        // Header: la beta compact-2026-01-12 presente.
        let beta = req.value(forHTTPHeaderField: "anthropic-beta") ?? ""
        #expect(beta.contains("compact-2026-01-12"))
        #expect(beta.contains("context-management-2025-06-27"))

        // Body: context_management.edits con clear + compact.
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(req.httpBody))
        let edits = try #require(body.at("context_management", "edits")?.arrayValue)
        let types = edits.compactMap { $0["type"]?.stringValue }
        #expect(types.contains(ContextManagementEdit.clearToolUses))
        #expect(types.contains(ContextManagementEdit.compact))
    }

    /// Sin relieve, el body NO lleva context_management (prefijo cacheado intacto).
    @Test func noReliefNoContextManagement() throws {
        let opts = try TestConfig.callOpts(authMode: .apiKey)
        let req = try ClaudeRequestBuilder.build(
            context: AssembledContext(messages: [.user("hola")]),
            tools: [], opts: opts)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(req.httpBody))
        #expect(body["context_management"] == nil)
    }
}
