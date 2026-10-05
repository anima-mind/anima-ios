import Foundation
import Testing
@testable import AnimaKit

// MARK: - Dobles de voz y del loop

final class MockVoice: VoiceCapturePort, SpeechOutputPort, @unchecked Sendable {
    let transcripts = Locked<[String?]>([])
    let route = Locked(VoiceRoute.glassesHFP)
    let spoken = Locked<[String]>([])
    let cancels = Locked(0)
    let stops = Locked(0)
    let hold = Locked(false)
    /// Karaoke: el TTS simulado reporta el rango de CADA palabra de la
    /// utterance (como AVSpeechSynthesizer), con una pausa entre cada una.
    let wordRanges = Locked(false)

    func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void) async -> String? {
        onRoute(route.value)
        while hold.value { try? await Task.sleep(nanoseconds: 2_000_000) }
        return transcripts.mutate { $0.isEmpty ? nil : $0.removeFirst() }
    }
    func cancel() { cancels.mutate { $0 += 1 }; hold.mutate { $0 = false } }
    func speak(_ text: String) async { spoken.mutate { $0.append(text) } }
    func speak(_ text: String, onRange: @escaping @Sendable (NSRange) -> Void) async {
        if wordRanges.value {
            let ns = text as NSString
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, range, _, _ in
                onRange(range)
            }
            for _ in 0..<3 { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        await speak(text)
    }
    func stop() { stops.mutate { $0 += 1 } }
}

/// Runner guionado: responde con el texto dado y registra lo recibido.
final class MockRunner: TurnRunner, @unchecked Sendable {
    let replies = Locked<[[LoopEvent]]>([])
    let received = Locked<[(content: [ContentBlock], surface: SurfaceID)]>([])
    func run(sessionId: SessionID, content: [ContentBlock], surface: SurfaceID) async -> AsyncStream<LoopEvent> {
        received.mutate { $0.append((content, surface)) }
        let events = replies.mutate { $0.isEmpty ? [] : $0.removeFirst() }
        return AsyncStream { c in
            for e in events { c.yield(e) }
            c.finish()
        }
    }
}

@MainActor
final class FakePhone: PhoneChatSurface {
    let id = SurfaceID.phoneChat
    let capabilities = SurfaceCapabilities.phoneChat
    let events = AsyncStream<SurfaceEvent> { $0.finish() }
    var rendered: [SurfaceContent] = []
    var lastMirroredTurnID: UUID?
    var focused: UUID?
    func render(_ content: SurfaceContent) async {
        rendered.append(content)
        if case .assistantTurn = content { lastMirroredTurnID = UUID() }
    }
    func focus(turn: UUID?) { focused = turn }
}

@MainActor
struct GlassesRig {
    let runtime: MockRuntime
    let body: GlassesBody
    let voice: MockVoice
    let runner: MockRunner
    let router: SurfaceRouter
    let phone: FakePhone
    let surface: GlassesHUDSurface
    let opened: Locked<[UUID?]>

    static func make(active: Bool = true, cameraTimeout: TimeInterval = 60) async -> GlassesRig {
        let runtime = MockRuntime()
        let body = await readyBody(runtime)
        let voice = MockVoice()
        let runner = MockRunner()
        let router = SurfaceRouter()
        let phone = FakePhone()
        router.register(phone)
        let opened = Locked<[UUID?]>([])
        let surface = GlassesHUDSurface(body: body, runner: runner, sessionId: "s1", voice: voice, speech: voice,
                                        router: router, cameraTimeout: cameraTimeout,
                                        openPhone: { id in opened.mutate { $0.append(id) } })
        await surface.start()
        if active {
            try? await body.ensureActive()
            _ = await body.waitUntilActive()
        }
        return GlassesRig(runtime: runtime, body: body, voice: voice, runner: runner, router: router,
                          phone: phone, surface: surface, opened: opened)
    }

    nonisolated var display: MockDisplay? { runtime.lastSession?.display }
    nonisolated var lastView: HUDView? { display?.sent.value.last }
}

@Suite("G1 — conversación en la cara (GlassesHUDSurface)")
@MainActor
struct GlassesConversationTests {

    static func reply(_ text: String) -> [LoopEvent] {
        [.textDelta(text), .turnFinished(stopReason: .endTurn)]
    }

    @Test func preguntaPorVozRespondeCardMasTTSYEspejaAlTelefono() async throws {
        let rig = await GlassesRig.make()
        rig.voice.transcripts.mutate { $0 = ["¿qué tengo mañana?"] }
        rig.runner.replies.mutate { $0 = [Self.reply("Mañana: standup a las 9. Almuerzo con Ana a la 1.")] }
        var seen: [SurfaceEvent] = []
        let events = rig.surface.events

        // Home (bienvenida) en las gafas; pinch en "Hablar".
        #expect(await eventually { await rig.body.lastRendered()?.name == "home" })
        rig.display?.tap(.talk)
        #expect(await eventually { await rig.surface.state.screen == .heard(transcript: "¿qué tengo mañana?") })
        #expect(rig.display?.sent.value.contains { $0.name == "listening" } == true)
        rig.display?.tap(.send)
        #expect(await eventually { if case .answer = await rig.surface.state.screen { return true } else { return false } })

        // El turno fue por el loop normal, marcado como gafas, con el prefijo de transcript.
        let received = try #require(rig.runner.received.value.first)
        #expect(received.surface == .glassesHUD)
        #expect(received.content == [.text(AudioTool.transcriptText("¿qué tengo mañana?"))])
        // TTS corto + card con el gist.
        // TTS por oración: la primera se dice apenas llega, la siguiente se encola.
        #expect(rig.voice.spoken.value == ["Mañana: standup a las 9.", "Almuerzo con Ana a la 1."])
        let answer = try #require(rig.lastView)
        #expect(answer.texts.contains { $0.content == "Mañana: standup a las 9." && $0.style == .heading })
        try HUDValidator.validate(answer)
        // Espejo en el teléfono: la conversación es UNA.
        #expect(rig.phone.rendered == [
            .userTurn(text: "¿qué tengo mañana?", origin: .glassesHUD),
            .assistantTurn(text: "Mañana: standup a las 9. Almuerzo con Ana a la 1.", origin: .glassesHUD),
        ])
        // Handoff "ver en el teléfono": abre el turno espejado.
        rig.display?.tap(.onPhone)
        #expect(await eventually { rig.opened.value.count == 1 })
        #expect(rig.opened.value.first == rig.phone.lastMirroredTurnID)
        #expect(rig.lastView?.name == "handoff")

        rig.surface.stop()
        for await e in events { seen.append(e) }
        #expect(seen.contains(.buttonTapped(.talk)))
        #expect(seen.contains(.voiceTranscript("¿qué tengo mañana?")))
        #expect(!seen.contains { if case .userText = $0 { return true } else { return false } })
    }

    @Test func fallbackAlMicDelTelefonoSeVeEnElHUD() async throws {
        let rig = await GlassesRig.make()
        rig.voice.route.mutate { $0 = .phoneMic }
        rig.voice.hold.mutate { $0 = true }
        await rig.surface.handle(.action(.talk))
        #expect(await eventually { await rig.surface.state.screen == .listening(viaPhone: true) })
        #expect(await eventually { rig.lastView?.texts.contains { $0.content == "Escuchando por el teléfono" } == true })
        rig.display?.tap(.cancel)
        #expect(await eventually { rig.voice.cancels.value >= 1 })
        #expect(await eventually { if case .home = await rig.surface.state.screen { return true } else { return false } })
    }

    @Test func rechazoYErrorSonCardsDelVocabulario() async throws {
        let rig = await GlassesRig.make()
        rig.runner.replies.mutate { $0 = [[.refused], [.error("Sin red.")], [.textDelta("Ups"), .stopped(.loopDetected)]] }
        await rig.surface.handle(.transcript(nil))   // sin efecto fuera de listening
        await rig.surface.handle(.action(.talk))
        rig.voice.cancel()
        await rig.surface.handle(.transcript("lee sus mensajes"))
        await rig.surface.handle(.action(.send))
        #expect(await eventually { if case .declined = await rig.surface.state.screen { return true } else { return false } })
        #expect(rig.phone.rendered.contains { if case .declined = $0 { return true } else { return false } })

        await rig.surface.handle(.action(.back))
        await rig.surface.handle(.action(.talk))
        await rig.surface.handle(.transcript("hola"))
        await rig.surface.handle(.action(.send))
        #expect(await eventually { await rig.surface.state.screen == .attention("Sin red.") })

        await rig.surface.handle(.action(.back))
        await rig.surface.handle(.action(.talk))
        await rig.surface.handle(.transcript("otra"))
        await rig.surface.handle(.action(.send))
        // Hubo texto antes del stop: se entrega lo que hubo.
        #expect(await eventually { if case .speaking = await rig.surface.state.screen { return true }
            if case .answer = await rig.surface.state.screen { return true }; return false })
    }

    @Test func backFisicoLimpiaYAvisaSalida() async throws {
        let rig = await GlassesRig.make()
        rig.voice.hold.mutate { $0 = true }
        await rig.surface.handle(.action(.talk))
        rig.runtime.lastSession?.endFromDevice()
        #expect(await eventually { if case .home = await rig.surface.state.screen { return true } else { return false } })
        #expect(rig.voice.cancels.value >= 1)
        #expect(rig.runtime.liveSessions == 0)
        // La Home queda como vista actual: al reconectar se re-envía sola.
        #expect(await rig.body.lastRendered()?.name == "home")
    }

    @Test func camaraConPinchEnLasGafas() async throws {
        let rig = await GlassesRig.make()
        let request = ConfirmationRequest(tool: GlassesCameraTool.name, operation: "capture_pov",
                                          summary: "Para ver qué estás mirando.", input: .object([:]))
        let approval = Task { await rig.surface.confirmCamera(request) }
        #expect(await eventually { rig.lastView?.name == "cameraConfirm" })
        #expect(rig.lastView?.texts.contains { $0.content == "¿Tomo una foto?" } == true)
        // Una segunda solicitud simultánea se niega (fail-closed).
        #expect(await rig.surface.confirmCamera(request) == false)
        rig.display?.tap(.cameraAllow)
        #expect(await approval.value)

        let denied = Task { await rig.surface.confirmCamera(request) }
        #expect(await eventually { rig.lastView?.name == "cameraConfirm" })
        rig.display?.tap(.cameraDeny)
        #expect(await denied.value == false)
    }

    @Test func camaraSinRespuestaExpira() async throws {
        let rig = await GlassesRig.make(cameraTimeout: 0.05)
        let request = ConfirmationRequest(tool: GlassesCameraTool.name, operation: "capture_pov",
                                          summary: "r", input: .object([:]))
        #expect(await rig.surface.confirmCamera(request) == false)
    }

    @Test func sinGafasActivasNadaSeProyecta() async throws {
        let rig = await GlassesRig.make(active: false)
        #expect(await rig.surface.glassesActive() == false)
        #expect(await rig.surface.project(HUDFlexBox(children: [])) == false)
        let request = ConfirmationRequest(tool: GlassesCameraTool.name, operation: "o", summary: "s", input: .null)
        #expect(await rig.surface.confirmCamera(request) == false)
        await #expect(throws: GlassesBodyError.self) { try await rig.surface.capturePOV() }
    }

    @Test func cardDelAgenteYFotoPOV() async throws {
        let rig = await GlassesRig.make()
        let card = HUDFlexBox(background: .card, children: [.text(HUDText("9:00 Standup", style: .heading))])
        #expect(await rig.surface.project(card))
        #expect(rig.lastView?.name == "agentCard")
        #expect(try await rig.surface.capturePOV() == Data([0xFF, 0xD8, 0xFF]))
        // Durante la captura de voz la card del agente no interrumpe.
        rig.voice.hold.mutate { $0 = true }
        await rig.surface.handle(.action(.talk))
        #expect(await rig.surface.project(card) == false)
        rig.voice.cancel()
    }

    @Test func estadoCorporalEnLaHome() async throws {
        let rig = await GlassesRig.make()
        var device = MockRuntime.display
        device.batteryPercent = 64
        rig.runtime.setDevices([device])
        #expect(await eventually { await rig.surface.state.status == "Batería 64% · toca Hablar para conversar." })
        #expect(await eventually { rig.lastView?.texts.contains { $0.content.hasPrefix("Batería 64%") } == true })
        #expect(GlassesHUDSurface.homeLine(GlassesStatus()) == nil)
        // Contenido del teléfono no se espeja en el HUD.
        await rig.surface.render(.assistantTurn(text: "x", origin: .phoneChat))
        await rig.surface.render(.status("pensando"))
        #expect(rig.surface.capabilities == .glassesHUD)
        #expect(rig.surface.id == .glassesHUD)
    }
}

@Suite("G1 — superficies, deep link y transcript único")
struct SurfaceRoutingTests {

    @MainActor
    @Test func routerEntregaAlOrigenYEspejaEnElTelefono() async {
        let router = SurfaceRouter()
        let phone = FakePhone()
        router.register(phone)
        #expect(router.phone === phone)
        await router.route(.assistantTurn(text: "hola", origin: .phoneChat))
        #expect(phone.rendered.count == 1)   // origen = teléfono: una sola vez
        await router.route(.userTurn(text: "q", origin: .glassesHUD))   // sin HUD registrado: solo espejo
        #expect(phone.rendered.count == 2)
        await router.route(.status("x"))
        #expect(phone.rendered.count == 3)
        #expect(SurfaceRouter.origin(of: .declined(text: "n", origin: .glassesHUD)) == .glassesHUD)
        #expect(SurfaceCapabilities.glassesHUD.freeText == false)
        #expect(SurfaceCapabilities.phoneChat.freeText)
    }

    @Test func deepLinkDelHandoff() throws {
        let turn = UUID()
        let url = AnimaDeepLink.chat(turn: turn).url
        #expect(url.absoluteString == "anima://chat?turn=\(turn.uuidString)")
        #expect(AnimaDeepLink.parse(url) == .chat(turn: turn))
        #expect(AnimaDeepLink.parse(AnimaDeepLink.chat(turn: nil).url) == .chat(turn: nil))
        // El callback de Meta AI (registro DAT) NO es un deep link propio.
        #expect(AnimaDeepLink.parse(URL(string: "anima://?metaWearablesAction=register")!) == nil)
        #expect(AnimaDeepLink.parse(URL(string: "https://chat")!) == nil)
    }

    @Test func turnosDeGafasEnElMismoTranscriptConMarca() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let provider = CapturingProvider([.text("Por el teléfono."), .text("Por las gafas."), .text("Sigo aquí.")])
        let loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [], serverTools: [], sleep: { _ in })
        let sid = try store.startSession()
        for await _ in await loop.run(sessionId: sid, userText: "hola") {}
        for await _ in await loop.run(sessionId: sid, content: [AudioTool.transcriptBlock("¿qué hay?")],
                                      surface: .glassesHUD) {}
        for await _ in await loop.run(sessionId: sid, userText: "¿y lo de antes?") {}

        #expect(try store.surfaces(sessionId: sid) == [.phoneChat, .phoneChat, .glassesHUD, .glassesHUD,
                                                        .phoneChat, .phoneChat])
        // Al volver al teléfono, el turno de gafas está en la historia del modelo.
        let third = try #require(provider.captures.value.last)
        #expect(third.messages.contains { $0.content == [AudioTool.transcriptBlock("¿qué hay?")] })
        // La pista de superficie solo va en el turno de gafas (system volátil).
        let hints = provider.captures.value.map { capture in
            capture.messages.contains { $0.role == .system && $0.content == [.text(AgentLoop.glassesSurfaceHint)] }
        }
        #expect(hints == [false, true, false])
    }
}
