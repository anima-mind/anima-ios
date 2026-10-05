import Foundation
import Testing
@testable import AnimaKit

@Suite struct HarnessClockTests {
    static let bogota = TimeZone(identifier: "America/Bogota")!
    /// 2026-10-05 14:30 hora de Bogotá (19:30 UTC).
    static let fixed = Date(timeIntervalSince1970: 1_791_228_600)

    @Test func clockLineIsSpanishWithZoneAndOffset() {
        let line = WorkingMemory.clockLine(for: Self.fixed, timeZone: Self.bogota)
        #expect(line == "Ahora: lunes 5 de octubre 2026, 14:30 (America/Bogota, UTC-5)")
    }

    @Test func clockLineHandlesHalfHourAndPositiveOffsets() {
        let kolkata = TimeZone(identifier: "Asia/Kolkata")!
        #expect(WorkingMemory.clockLine(for: Self.fixed, timeZone: kolkata).hasSuffix("(Asia/Kolkata, UTC+5:30)"))
        let utc = TimeZone(identifier: "Africa/Abidjan")!
        #expect(WorkingMemory.clockLine(for: Self.fixed, timeZone: utc).hasSuffix("(Africa/Abidjan, UTC+0)"))
    }

    @Test func clockIsTheLastSystemMessageAndClears() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let sid = try store.startSession()
        let wm = WorkingMemory(store: store)
        await wm.updateBodyStatus("Cuerpo: solo teléfono")
        await wm.updateClock(Self.fixed, timeZone: Self.bogota)
        let messages = try await wm.assemble(.text("recuérdame mañana", sessionId: sid))
        let systems = messages.filter { $0.role == .system }
        #expect(systems.count == 3)
        #expect(systems.last?.content == [.text(WorkingMemory.clockLine(for: Self.fixed, timeZone: Self.bogota))])
        #expect(messages.last?.role == .user)

        await wm.updateClock(nil)
        let clean = try await wm.assemble(.text("otra", sessionId: sid))
        #expect(!clean.contains { $0.content.contains { if case .text(let t) = $0 { t.hasPrefix("Ahora:") } else { false } } })
    }

    /// El loop usa el reloj inyectado; en Claude la línea va en el bloque volátil
    /// del system top-level y JAMÁS en el base cacheado.
    @Test func loopInjectsClockIntoVolatileBlockOnly() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let provider = CapturingProvider([.text("listo")])
        let loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [], serverTools: [],
                             clock: { Self.fixed }, sleep: { _ in })
        let sid = try store.startSession()
        for await _ in await loop.run(sessionId: sid, userText: "hola") {}
        let capture = try #require(provider.captures.value.first)
        let expected = WorkingMemory.clockLine(for: Self.fixed, timeZone: .current)
        #expect(capture.messages.last(where: { $0.role == .system })?.content == [.text(expected)])

        let req = try ClaudeRequestBuilder.build(context: AssembledContext(messages: capture.messages),
                                                 tools: [], opts: try TestConfig.callOpts(authMode: .apiKey))
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(req.httpBody))
        guard case .array(let sys) = body["system"]! else { Issue.record("system no es array"); return }
        let texts: [String] = sys.compactMap { block -> String? in if case .string(let t)? = block.at("text") { return t } else { return nil } }
        #expect(texts.last?.hasSuffix(expected) == true)
        #expect(texts.dropLast().allSatisfy { !$0.contains("Ahora:") })
    }
}
