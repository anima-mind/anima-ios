import Foundation
import Testing
@testable import AnimaKit

// Campo #5: "Hey Meta, take a photo" es de Meta AI y saca al usuario de Anima.
// Botón "Foto" en la Home: captura DIRECTA (la iniciación del dueño es el
// consentimiento, doc 04 §8) → turno multimodal → card + TTS normal. La tool
// glasses_camera del agente sigue con su confirmación.

@Suite("Campo — botón Foto en la Home del HUD (máquina de estados)")
struct HUDPhotoStateTests {
    typealias S = HUDConversationState
    static let image = ContentBlock.image(mediaType: "image/jpeg", base64: "AAAA")

    @Test func homeCapturaPiensaYResponde() {
        var (s, fx) = HUDStateMachine.reduce(S(status: "ok"), .action(.photo))
        #expect(s.screen == .capturing); #expect(fx == [.capturePhoto])
        (s, fx) = HUDStateMachine.reduce(s, .photoCaptured(Self.image))
        #expect(s.screen == .thinking(question: HUDPhoto.question)); #expect(fx == [.submitPhoto(Self.image)])
        (s, fx) = HUDStateMachine.reduce(s, .turnFinished(reply: "Es una taza de café."))
        guard case .speaking = s.screen else { Issue.record("no speaking"); return }
        (s, fx) = HUDStateMachine.reduce(s, .speechFinished)
        guard case .answer = s.screen else { Issue.record("no answer"); return }
    }

    @Test func cancelBackErrorYSalidaVuelvenAlHome() {
        let home = HUDScreen.home(status: nil)
        for action in [HUDActionID.cancel, .back] {
            let r = HUDStateMachine.reduce(S(screen: .capturing), .action(action))
            #expect(r.state.screen == home); #expect(r.effects == [.cancelCapture])
        }
        let failed = HUDStateMachine.reduce(S(screen: .capturing), .photoFailed(HUDPhoto.failure))
        #expect(failed.state.screen == .attention(HUDPhoto.failure)); #expect(failed.effects == [.returnHomeLater])
        #expect(HUDStateMachine.reduce(failed.state, .action(.back)).state.screen == home)
        #expect(HUDStateMachine.reduce(S(screen: .capturing), .exited).effects == [.cancelCapture])
        let camera = HUDStateMachine.reduce(S(screen: .capturing), .cameraRequested(reason: "r"))
        #expect(camera.effects == [.cancelCapture]); #expect(camera.state.suspended == home)
        // La foto solo arranca desde la Home; fuera de captura, sus eventos no hacen nada.
        #expect(HUDStateMachine.reduce(S(screen: .thinking(question: "q")), .action(.photo)).effects.isEmpty)
        #expect(HUDStateMachine.reduce(S(), .photoCaptured(Self.image)).state == S())
    }

    @Test func homeConBotonFotoYCapturaSonArbolesValidos() throws {
        let home = HUDRenderer.render(.home(status: nil))
        try HUDValidator.validate(home)
        let foto = try #require(home.buttons.first { $0.action == .photo })
        #expect(foto.label == "Foto"); #expect(foto.icon == .videoCamera)
        let capturing = HUDRenderer.render(.capturing)
        try HUDValidator.validate(capturing)
        #expect(capturing.actions.contains(.back)); #expect(capturing.actions.contains(.cancel))
    }
}

@Suite("Campo — botón Foto: captura directa por el camino multimodal")
@MainActor
struct GlassesPhotoButtonTests {

    final class CountingConfirmation: ConfirmationProvider, @unchecked Sendable {
        let phone = Locked(0)
        func confirm(_ request: ConfirmationRequest) async -> Bool { phone.mutate { $0 += 1 }; return true }
    }

    @Test func botonFotoNoPasaPorConfirmacionYLaToolSi() async throws {
        let runtime = MockRuntime()
        let body = await readyBody(runtime)
        try await body.ensureActive()
        _ = await body.waitUntilActive()
        runtime.lastSession?.photo.mutate { $0 = .success(makeJPEG(width: 400, height: 300)) }

        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let round: [ProviderEvent] = [
            .messageStart(id: "m1", model: "claude-opus-4-8"),
            .toolUseStart(id: "toolu_1", name: "glasses_camera"),
            .toolUseInputDelta(#"{"reason":"ver"}"#),
            .blockStop(index: 0),
            .messageDelta(stopReason: .toolUse, usage: Usage(inputTokens: 10, outputTokens: 5)),
            .messageStop,
        ]
        let provider = CapturingProvider([.text("Es una pared azul. ¿Quieres guardarla?"), round, .text("Listo.")])
        let host = LateBoundGlassesHost()
        let phone = CountingConfirmation()
        let glassesAsked = Locked(0)
        let loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [GlassesCameraTool(host: host)], serverTools: [],
                             confirmation: SurfaceConfirmationRouter(phone: phone, glasses: { _ in
                                 glassesAsked.mutate { $0 += 1 }; return true
                             }),
                             sleep: { _ in })
        let sid = try store.startSession()
        let voice = MockVoice()
        let router = SurfaceRouter()
        let fakePhone = FakePhone()
        router.register(fakePhone)
        let surface = GlassesHUDSurface(body: body, runner: loop, sessionId: sid, voice: voice, speech: voice,
                                        router: router)
        host.bind(surface, confirm: nil)
        await surface.start()

        // Pinch en "Foto" desde la Home.
        runtime.lastSession?.display.tap(.photo)
        #expect(await eventually { if case .answer = await surface.state.screen { return true } else { return false } })
        #expect(runtime.lastSession?.display.sent.value.contains { $0.name == "capturing" } == true)
        #expect(runtime.lastSession?.display.sent.value.contains { $0.name == "cameraConfirm" } == false)
        #expect(phone.phone.value == 0)
        #expect(glassesAsked.value == 0, "el botón del dueño NO pasa por ConfirmationProvider")
        // La foto entró como turno multimodal: texto fijo + image block, marcado gafas.
        let first = try #require(provider.captures.value.first)
        let user = try #require(first.messages.last { $0.role == .user })
        #expect(user.content.first == .text(HUDPhoto.prompt))
        #expect(user.content.contains { if case .image = $0 { return true } else { return false } })
        #expect(voice.spoken.value.joined(separator: " ").contains("pared azul"))
        #expect(fakePhone.rendered.first == .userTurn(text: HUDPhoto.question, origin: .glassesHUD))

        // La TOOL glasses_camera del agente SÍ sigue pasando por la confirmación.
        for await _ in await loop.run(sessionId: sid, content: [.text("¿qué ves?")], surface: .glassesHUD) {}
        #expect(glassesAsked.value == 1)
        surface.stop()
    }

    @Test func camaraFallaMuestraErrorYVuelveSolaAlHome() async throws {
        let runtime = MockRuntime()
        let body = await readyBody(runtime)
        try await body.ensureActive()
        _ = await body.waitUntilActive()
        runtime.lastSession?.photo.mutate { $0 = .failure(MockError("hinges")) }
        let voice = MockVoice()
        let surface = GlassesHUDSurface(body: body, runner: MockRunner(), sessionId: "s", voice: voice, speech: voice,
                                        errorDwell: 0.05)
        await surface.start()
        await surface.handle(.action(.photo))
        #expect(await eventually { await surface.state.screen == .attention(HUDPhoto.failure) })
        #expect(await eventually { await surface.state.screen == .home(status: nil) })

        // Foto que no es imagen: mismo error breve.
        runtime.lastSession?.photo.mutate { $0 = .success(Data([1, 2, 3])) }
        await surface.handle(.action(.photo))
        #expect(await eventually { await surface.state.screen == .attention(HUDPhoto.failure) })
        // Si el dueño ya se movió, el regreso automático no lo pisa.
        await surface.handle(.action(.back))
        await surface.handle(.action(.talk))
        voice.cancel()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(surface.state.screen != .attention(HUDPhoto.failure))

        // Cancelar durante la captura: vuelve al Home sin turno.
        runtime.lastSession?.photo.mutate { $0 = .success(makeJPEG()) }
        await surface.handle(.action(.back))
        await surface.handle(.action(.photo))
        await surface.handle(.action(.cancel))
        #expect(surface.state.screen == .home(status: nil))
        surface.stop()
    }
}
