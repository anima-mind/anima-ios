import Foundation
import GRDB
import Testing
@testable import AnimaKit

/// Lectura cooperativa larga (se corta al cancelar).
private struct LongRead: SensorimotorTool {
    var spec: ToolSpec {
        .client(name: "slow_read", description: "lee", inputSchema: .object(["type": .string("object")]))
    }
    func execute(_ input: JSONValue) async -> ToolResult {
        try? await Task.sleep(for: .seconds(60))
        return ToolResult(content: "leído")
    }
}

/// Pide `slow_read`; tras el resultado, texto.
private final class SlowReadProvider: Provider, @unchecked Sendable {
    func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        let last = ctx.messages.last(where: { $0.role == .user })?.content ?? []
        let afterTool = last.contains { if case .toolResult = $0 { return true }; return false }
        let events: [ProviderEvent] = afterTool
            ? [.messageStart(id: "t", model: "x"), .textDelta("Listo."), .blockStop(index: 0),
               .messageDelta(stopReason: .endTurn, usage: Usage()), .messageStop]
            : [.messageStart(id: "u", model: "x"), .toolUseStart(id: "toolu_\(UUID().uuidString.prefix(6))", name: "slow_read"),
               .toolUseInputDelta("{}"), .blockStop(index: 0), .messageDelta(stopReason: .toolUse, usage: Usage()),
               .messageStop]
        return AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            c.finish()
        }
    }
}

/// Un turno que jamás sale de la cola (nunca emite .started).
private struct QueuedForeverRunner: TurnRunner {
    func run(sessionId: SessionID, content: [ContentBlock], surface: SurfaceID) async -> AsyncStream<LoopEvent> {
        AsyncStream { _ in }
    }
}

@MainActor
@Suite("Review #38 ronda 8 — cámara de las gafas cancelada en cualquier punto")
struct GlassesCameraCancelTests {
    // MEDIO 1 (repro del review, con cameraTimeout 60 s para que el timeout no
    // lo tape): la cancelación llega en cualquier yield, también durante
    // glassesActive(). Se niega YA (no a los 60 s), y la card del turno
    // cancelado no queda en las gafas.
    @Test func cancelarConfirmCameraEnCualquierPunto() async throws {
        let rig = await GlassesRig.make(cameraTimeout: 60)
        let request = ConfirmationRequest(tool: GlassesCameraTool.name, operation: "capture_pov",
                                          summary: "Para ver.", input: .object([:]))
        for yields in 0...4 {
            for _ in 0..<40 {
                let answered = Locked<Bool?>(nil)
                let ask = Task.detached { let v = await rig.surface.confirmCamera(request); answered.mutate { $0 = v } }
                for _ in 0..<yields { await Task.yield() }
                ask.cancel()
                let done = await finishes(ask, within: .seconds(5))
                #expect(done, "la cancelación se perdió con yields=\(yields)")
                if !done { await rig.surface.handle(.action(.cameraDeny)); await ask.value }
                #expect(answered.value == false)
                #expect(await eventually {
                    if case .cameraConfirm = await rig.surface.state.screen { return false }
                    return rig.lastView?.name != "cameraConfirm"
                }, "card colgada con yields=\(yields)")
            }
        }
        // Y una confirmación nueva funciona (nada quedó retenido).
        let next = Task { await rig.surface.confirmCamera(request) }
        #expect(await eventually { rig.lastView?.name == "cameraConfirm" })
        rig.display?.tap(.cameraAllow)
        #expect(await next.value)
    }
}

@MainActor
@Suite("Review #38 ronda 8 — cancelar no castiga la práctica del skill")
struct CancelledSkillPracticeTests {
    @Test func tresTurnosCanceladosNoCuentanComoFallo() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let notes = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = SkillEngine(queue: queue, directory: try SkillFixtures.standard())
        let loop = AgentLoop(provider: SlowReadProvider(), store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [NotesTool(root: notes), LongRead()],
                             serverTools: [], permissionPolicy: .app(ownerAllowlist: { [] }),
                             skillEngine: engine, sleep: { _ in })
        let sid = try store.startSession()
        #expect(await engine.bestMatch("apunta esto en mi nota diaria")?.skill.name == "nota-diaria")
        for _ in 0..<3 {
            let turn = Task {
                for await event in await loop.run(sessionId: sid, content: [.text("apunta esto en mi nota diaria")]) {
                    if case .toolStarted = event { return }
                }
            }
            await turn.value
            #expect(await finishes(Task { await loop.waitUntilIdle() }, within: .seconds(20)))
        }
        let stats = await engine.stats("nota-diaria")
        #expect((stats?.totalFail ?? 0) == 0)
        #expect((stats?.successStreak ?? 0) == 0)
        #expect(stats?.practiced != true)
        #expect(SkillTurn.outcome(end: .stopped(.cancelled), skillToolFailed: false) == .neutral)
        #expect(SkillTurn.outcome(end: .stopped(.loopDetected), skillToolFailed: false) == .failure)
    }
}

@MainActor
@Suite("Review #38 ronda 8 — confirmaciones, Siri en la cola, gafas y Pricing")
struct Round8MinorTests {
    // Una cancelación tardía (la solicitud ya se resolvió) no afecta a la
    // siguiente ni deja rastro: la cancelación vive en su solicitud.
    @Test func cancelacionTardiaNoTocaLaSiguiente() async {
        let center = ConfirmationCenter()
        for i in 0..<200 {
            let ask = Task { await center.confirm(ConfirmationRequest(tool: "t", operation: "o", summary: "a\(i)", input: .null)) }
            #expect(await eventually { await MainActor.run { center.pending?.summary == "a\(i)" } })
            center.resolve(true)
            #expect(await ask.value)
            ask.cancel()   // tarde: ya resuelta
        }
        let next = Task { await center.confirm(ConfirmationRequest(tool: "t", operation: "o", summary: "b", input: .null)) }
        #expect(await eventually { await MainActor.run { center.pending?.summary == "b" } })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(center.pending?.summary == "b")   // ninguna cancelación vieja la cerró
        center.resolve(true)
        #expect(await next.value)
    }

    @Test func siriCortadaEnLaColaNoAvisa() async {
        let spy = SiriSpy()
        let siri = spy.runner(QueuedForeverRunner(), deadline: .milliseconds(20), hardLimit: .milliseconds(60))
        #expect(await siri.ask("hola") == .deferred)
        await siri.release()
        await spy.waitSettled()
        #expect(spy.delivered.value.last == .turnDropped(origin: .siri))
        #expect(spy.settled.value == [nil])
    }

    // Gafas: cancelado ya corriendo → "interrumpido"; cancelado en la cola → se quita.
    @Test func gafasDistinguenInterrumpidoDeQuitado() async throws {
        for (runner, expected) in [(SiriGatedRunner([.textDelta("x")], gated: true) as any TurnRunner,
                                    SurfaceContent.turnFailed(text: GlassesHUDSurface.interruptedText, origin: .glassesHUD)),
                                   (QueuedForeverRunner(), SurfaceContent.turnDropped(origin: .glassesHUD))] {
            let body = await readyBody(MockRuntime())
            let voice = MockVoice()
            let router = SurfaceRouter()
            let phone = FakePhone()
            router.register(phone)
            let surface = GlassesHUDSurface(body: body, runner: runner, sessionId: "s1", voice: voice, speech: voice,
                                            router: router)
            await surface.start()
            try? await body.ensureActive()
            _ = await body.waitUntilActive()
            await surface.handle(.action(.talk))
            await surface.handle(.transcript("hola"))
            await surface.handle(.action(.send))
            #expect(await eventually { await MainActor.run { phone.rendered.contains(.userTurn(text: "hola", origin: .glassesHUD)) } })
            try await Task.sleep(for: .milliseconds(50))
            await surface.handle(.action(.cancel))
            #expect(await eventually { await MainActor.run { phone.rendered.last == expected } })
            surface.stop()
            withExtendedLifetime(router) {}
        }
    }

    // Pricing.load actualiza la tabla (aislada en un sandbox de la tarea).
    @Test func loadActualizaLaTabla() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"gpt-5": {"in": 9, "out": 90}}
        """.utf8))
        Pricing.$sandbox.withValue(Pricing.Sandbox()) {
            #expect(Pricing.rate(for: "gpt-5.9").input == 1.75 || Pricing.rate(for: "gpt-5.9").input == 5)
            Pricing.load(json)
            #expect(Pricing.rate(for: "gpt-5.9").input == 9)
            Pricing.load(.object(["rota": .string("x")]))   // sin tarifas válidas: no cambia
            #expect(Pricing.rate(for: "gpt-5.9").input == 9)
        }
        #expect(Pricing.rate(for: "gpt-5.2").input == 1.75)   // la global, intacta
    }
}
