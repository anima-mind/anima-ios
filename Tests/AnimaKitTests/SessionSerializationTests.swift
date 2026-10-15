import Foundation
import Testing
@testable import AnimaKit

/// Tool aferente que IGNORA la cancelación: tarda `delay` pase lo que pase.
private struct StubbornReadTool: SensorimotorTool {
    let delay: TimeInterval
    let finished = Locked(0)
    var spec: ToolSpec {
        .client(name: "slow_read", description: "lee lento", inputSchema: .object(["type": .string("object")]))
    }
    func execute(_ input: JSONValue) async -> ToolResult {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { c.resume() }
        }
        finished.mutate { $0 += 1 }
        return ToolResult(content: "leído")
    }
}

/// Responde según el contexto: pide la tool al turno viejo, cierra tras su
/// resultado y contesta la pregunta nueva.
private final class ContextProvider: Provider, @unchecked Sendable {
    func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        let last = ctx.messages.last(where: { $0.role == .user })?.content ?? []
        let asksNew = last.contains { if case .text(let t) = $0 { return t.contains("pregunta nueva") }; return false }
        let afterTool = last.contains { if case .toolResult = $0 { return true }; return false }
        let events: [ProviderEvent]
        if asksNew {
            events = [.messageStart(id: "m2", model: "x"), .textDelta("Respuesta 2"), .blockStop(index: 0),
                      .messageDelta(stopReason: .endTurn, usage: Usage()), .messageStop]
        } else if afterTool {
            events = [.messageStart(id: "m1b", model: "x"), .textDelta("Respuesta 1"), .blockStop(index: 0),
                      .messageDelta(stopReason: .endTurn, usage: Usage()), .messageStop]
        } else {
            events = [.messageStart(id: "m1", model: "x"), .toolUseStart(id: "toolu_1", name: "slow_read"),
                      .toolUseInputDelta("{}"), .blockStop(index: 0),
                      .messageDelta(stopReason: .toolUse, usage: Usage()), .messageStop]
        }
        return AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            c.finish()
        }
    }
}

@Suite("Review #38 ronda 5 — un turno a la vez por sesión dentro del loop")
struct SessionSerializationTests {
    /// Cada tool_use tiene EXACTAMENTE un tool_result en el mensaje siguiente.
    static func paired(_ window: [Message]) -> Bool {
        for (i, message) in window.enumerated() {
            let uses = message.content.compactMap { block -> String? in
                if case .toolUse(let id, _, _) = block { return id }
                return nil
            }
            guard !uses.isEmpty else { continue }
            guard i + 1 < window.count else { return false }
            let results = window[i + 1].content.compactMap { block -> String? in
                if case .toolResult(let id, _, _) = block { return id }
                return nil
            }
            if results.sorted() != uses.sorted() { return false }
        }
        let allResults = window.flatMap(\.content).compactMap { block -> String? in
            if case .toolResult(let id, _, _) = block { return id }
            return nil
        }
        return Set(allResults).count == allResults.count
    }

    // Repro del review: turno de gafas con una tool que ignora la cancelación,
    // cancel + compuerta soltada por tope (50 ms) y el chat pregunta algo nuevo.
    @Test func elTurnoNuevoEsperaYLaVentanaQuedaPareada() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let tool = StubbornReadTool(delay: 0.4)
        let loop = AgentLoop(provider: ContextProvider(), store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [tool], serverTools: [],
                             permissionPolicy: .app(ownerAllowlist: { [] }), sleep: { _ in })
        let sid = try store.startSession()
        let gate = TurnGate()
        let glasses = try #require(gate.begin(.glassesHUD))
        let old = Task {
            for await event in await loop.run(sessionId: sid, content: [.text("pregunta vieja")], surface: .glassesHUD) {
                if case .toolStarted = event { return }
            }
        }
        await old.value          // el consumidor de las gafas cortó (cancel)
        await gate.end(glasses, after: loop, limit: .milliseconds(50))
        #expect(gate.current == nil)
        #expect(await loop.turnsInFlight == 1)   // el productor sigue en la tool

        var reply = ""
        for await event in await loop.run(sessionId: sid, content: [.text("pregunta nueva")], surface: .phoneChat) {
            if case .textDelta(let d) = event { reply += d }
        }
        #expect(reply == "Respuesta 2")
        #expect(tool.finished.value == 1)        // el nuevo esperó a que terminara el viejo

        let window = try store.window(sessionId: sid)
        #expect(Self.paired(window))
        let texts = window.map { message in
            message.content.map { block -> String in
                switch block {
                case .text(let t): return t
                case .toolUse(let id, _, _): return "use:\(id)"
                case .toolResult(let id, _, _): return "result:\(id)"
                default: return "?"
                }
            }.joined(separator: "|")
        }
        let result = try #require(texts.firstIndex(of: "result:toolu_1"))
        let newQuestion = try #require(texts.firstIndex { $0.contains("pregunta nueva") })
        #expect(texts.first == "pregunta vieja")
        #expect(texts[1] == "use:toolu_1")
        #expect(result == 2)
        #expect(newQuestion > result)
        #expect(texts.last == "Respuesta 2")
    }

    // El timeout de una tool que ignora la cancelación no espera a la tool: el
    // resultado es el error de timeout (uno solo) y la tool se abandona.
    @Test func elTimeoutNoEsperaAUnaToolTerca() async {
        // La tool tarda 30 s; si el timeout la esperara, la llamada duraría eso.
        let tool = StubbornReadTool(delay: 30)
        let sensorimotor = Sensorimotor(tools: [tool], policy: .app(ownerAllowlist: { [] }), timeout: 0.1)
        let start = ContinuousClock.now
        let result = await sensorimotor.execute(name: "slow_read", input: .object([:]))
        #expect(ContinuousClock.now - start < .seconds(15))
        #expect(result.isError)
        #expect(result.content.contains("timeout"))
        #expect(tool.finished.value == 0)
    }

    @Test func sesionesDistintasNoSeEsperan() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let tool = StubbornReadTool(delay: 0.4)
        let loop = AgentLoop(provider: ContextProvider(), store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [tool], serverTools: [],
                             permissionPolicy: .app(ownerAllowlist: { [] }), sleep: { _ in })
        let a = try store.startSession(), b = try store.startSession()
        let old = Task {
            for await event in await loop.run(sessionId: a, content: [.text("pregunta vieja")]) {
                if case .toolStarted = event { return }
            }
        }
        await old.value
        var reply = ""
        for await event in await loop.run(sessionId: b, content: [.text("pregunta nueva")]) {
            if case .textDelta(let d) = event { reply += d }
        }
        #expect(reply == "Respuesta 2")
        #expect(tool.finished.value == 0)   // la otra sesión no esperó
        await loop.waitUntilIdle()
        #expect(tool.finished.value == 1)
    }
}

@MainActor
@Suite("Review #38 ronda 5 — gafas canceladas esperando la compuerta")
struct GlassesCancelWhileWaitingTests {
    @Test func cancelarMientrasEsperaLaCompuertaNoCorreElTurno() async throws {
        let body = await readyBody(MockRuntime())
        let voice = MockVoice()
        let runner = MockRunner()
        let gate = TurnGate()
        let surface = GlassesHUDSurface(body: body, runner: runner, gate: gate, gateRetry: .seconds(2),
                                        sessionId: "s1", voice: voice, speech: voice)
        await surface.start()
        try? await body.ensureActive()
        _ = await body.waitUntilActive()
        // "uno" fue cancelado y su productor aún tiene la compuerta.
        let uno = try #require(gate.begin(.glassesHUD))
        Task.detached {
            try? await Task.sleep(for: .milliseconds(300))
            gate.end(uno)
        }
        await surface.handle(.action(.talk))
        await surface.handle(.transcript("dos"))
        await surface.handle(.action(.send))     // "dos" espera la compuerta…
        await surface.handle(.action(.cancel))   // …y se cancela
        #expect(await eventually { gate.current == nil })
        try await Task.sleep(for: .milliseconds(400))
        #expect(runner.received.value.isEmpty)   // "dos" no corrió ni se persistió
        #expect(gate.current == nil)             // y no quedó con la compuerta
        surface.stop()
    }
}

@Suite("Review #38 ronda 5 — p. m. seguido de puntuación")
struct PMPunctuationTests {
    @Test func pmConComaOParentesisNoCorta() {
        #expect(HUDSummary.sentences("Llego a las 4 p. m., te aviso.") == ["Llego a las 4 p. m., te aviso."])
        #expect(HUDSummary.sentences("La cita (4 p. m.) sigue. Bien.") == ["La cita (4 p. m.) sigue.", "Bien."])
        var segmenter = StreamingSentenceSegmenter()
        var said: [String] = []
        for delta in ["Llego a las 4 p. ", "m., te aviso. Ch", "ao."] { said += segmenter.feed(delta) }
        said += segmenter.finish()
        #expect(said == ["Llego a las 4 p. m., te aviso.", "Chao."])
    }
}
