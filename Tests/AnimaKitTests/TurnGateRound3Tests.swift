import Foundation
import Testing
@testable import AnimaKit

/// Cámara de mentira con el nombre real: eferente, pide confirmación.
private struct FakeCamera: SensorimotorTool {
    let ran: Locked<Int>
    var spec: ToolSpec {
        .client(name: GlassesCameraTool.name, description: "foto", inputSchema: .object(["type": .string("object")]))
    }
    func kind(for input: JSONValue) -> ToolKind { .efferent }
    func execute(_ input: JSONValue) async -> ToolResult {
        ran.mutate { $0 += 1 }
        return ToolResult(content: "foto")
    }
}

/// Runner cuyo productor sigue vivo después de que su stream termina, hasta
/// que el test lo suelta (`finishProducer`): sin relojes.
private final class LingeringRunner: TurnRunner, @unchecked Sendable {
    let producing = Locked(false)
    func run(sessionId: SessionID, content: [ContentBlock], surface: SurfaceID) async -> AsyncStream<LoopEvent> {
        producing.mutate { $0 = true }
        return AsyncStream { c in
            c.yield(.textDelta("hola"))
            c.finish()
        }
    }
    func finishProducer() { producing.mutate { $0 = false } }
    func waitUntilIdle() async {
        while producing.value { try? await Task.sleep(for: .milliseconds(2)) }
    }
}

/// Provider lento: el turno sigue produciendo después de que el consumidor corta.
private struct SlowProvider: Provider {
    let finished: Locked<Bool>
    func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        let finished = self.finished
        return AsyncThrowingStream { c in
            Task {
                c.yield(.messageStart(id: "m", model: "x"))
                c.yield(.textDelta("Empiezo"))
                try? await Task.sleep(for: .milliseconds(120))
                finished.mutate { $0 = true }
                c.yield(.messageStop)
                c.finish()
            }
        }
    }
}

@MainActor
@Suite("Review #38 ronda 3 — compuerta antes de espejar, cada turno cierra el suyo")
struct TurnGateRound3Tests {
    private func chat() throws -> ChatViewModel {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        return ChatViewModel(loop: try FullHistoryStoreTests.loop(store, queue), sessionId: try store.startSession())
    }

    /// El router se devuelve para RETENERLO: la superficie lo guarda weak y,
    /// si se liberara, un espejo indebido no llegaría al chat (m4).
    private func glasses(gate: TurnGate, chat: ChatViewModel)
        async -> (GlassesHUDSurface, MockRunner, MockVoice, SurfaceRouter) {
        let body = await readyBody(MockRuntime())
        let voice = MockVoice()
        let runner = MockRunner()
        let router = SurfaceRouter()
        router.register(chat)
        let surface = GlassesHUDSurface(body: body, runner: runner, gate: gate, sessionId: "s1", voice: voice,
                                        speech: voice, router: router)
        await surface.start()
        try? await body.ensureActive()
        _ = await body.waitUntilActive()
        return (surface, runner, voice, router)
    }

    // MEDIO A: el chat responde y el dueño habla por las gafas. Las gafas no
    // espejan nada (lo dicen en el HUD) y el chat sigue ocupado.
    @Test func gafasConLaCompuertaTomadaNoEspejanNiLiberanElChat() async throws {
        let chat = try chat()
        let gate = TurnGate()
        chat.turnGate = gate
        let chatTurn = try #require(gate.begin(.phoneChat))   // el run() del chat en vuelo
        let (surface, runner, voice, router) = await glasses(gate: gate, chat: chat)
        voice.transcripts.mutate { $0 = ["¿qué tengo?"] }
        await surface.handle(.action(.talk))
        await surface.handle(.transcript("¿qué tengo?"))
        await surface.handle(.action(.send))
        #expect(await eventually { await surface.state.screen == .attention(GlassesHUDSurface.busyText) })
        #expect(runner.received.value.isEmpty)
        #expect(chat.messages.isEmpty)
        #expect(chat.isStreaming)
        #expect(gate.current == .phoneChat)
        chat.input = "otra cosa"
        await chat.send()
        #expect(chat.input == "otra cosa")   // no se pierde
        surface.stop()
        withExtendedLifetime(router) {}
        gate.end(chatTurn)
    }

    // MEDIO B: Siri y gafas espejados a la vez (orden cruzado): cada respuesta
    // o fallo cierra SU burbuja, en su lugar, y el chat queda ocupado hasta el último.
    @Test func cadaTurnoEspejadoCierraElSuyo() async throws {
        let chat = try chat()
        await chat.render(.userTurn(text: "pregunta por Siri", origin: .siri))
        await chat.render(.userTurn(text: "pregunta por gafas", origin: .glassesHUD))
        await chat.render(.status("Estoy respondiendo algo que me pediste por Siri."))
        #expect(chat.isStreaming)
        #expect(chat.messages.count == 4)
        await chat.render(.assistantTurn(text: "Respuesta de Siri", origin: .siri))
        #expect(chat.messages[1].text == "Respuesta de Siri")   // en su lugar, no al final
        #expect(chat.messages[1].isStreaming == false)
        #expect(chat.messages[3].isStreaming)                   // la de gafas sigue en curso
        #expect(chat.isStreaming)
        await chat.render(.turnFailed(text: "Sin red.", origin: .glassesHUD))
        #expect(chat.messages[3].text == "Sin red.")
        #expect(chat.messages[3].isError)
        #expect(!chat.isStreaming)
        #expect(chat.messages.count == 4)
    }

    @Test func ocupadoSeDerivaDeLaCompuerta() throws {
        let chat = try chat()
        let gate = TurnGate()
        chat.turnGate = gate
        #expect(!chat.isStreaming)
        let glassesTurn = try #require(gate.begin(.glassesHUD))
        #expect(chat.isStreaming)
        gate.end(glassesTurn)
        #expect(!chat.isStreaming)
    }

    // Menor 4 (§8): desde Siri, la cámara de las gafas no se confirma por voz.
    @Test func camaraDeLasGafasDesdeSiriSeNiega() async {
        let ran = Locked(0)
        let siriAsked = Locked(0)
        struct Siri: ConfirmationProvider {
            let asked: Locked<Int>
            func confirm(_ request: ConfirmationRequest) async -> Bool { asked.mutate { $0 += 1 }; return true }
        }
        let router = SurfaceConfirmationRouter(phone: FailClosedConfirmation(), glasses: { _ in true },
                                               siri: Siri(asked: siriAsked))
        let sensorimotor = Sensorimotor(tools: [FakeCamera(ran: ran)], policy: .app(ownerAllowlist: { [] }),
                                        confirmation: router)
        let fromSiri = await sensorimotor.execute(name: GlassesCameraTool.name, input: .object([:]), surface: .siri)
        #expect(fromSiri.content == SurfaceConfirmationRouter.siriCameraRefusal)
        #expect(fromSiri.isError)
        #expect(ran.value == 0)
        #expect(siriAsked.value == 0)
        // Desde el teléfono o las gafas sigue el pinch en las gafas.
        let fromGlasses = await sensorimotor.execute(name: GlassesCameraTool.name, input: .object([:]),
                                                     surface: .glassesHUD)
        #expect(fromGlasses.content == "foto")
        #expect(await router.confirm(ConfirmationRequest(tool: GlassesCameraTool.name, operation: "x", summary: "s",
                                                         input: .null, surface: .siri)) == false)
    }

    // Menor 7: la compuerta se suelta cuando el productor terminó, no antes.
    @Test func laCompuertaSeSueltaCuandoElProductorTermina() async throws {
        let gate = TurnGate()
        let runner = LingeringRunner()
        let token = try #require(gate.begin(.glassesHUD))
        for await _ in await runner.run(sessionId: "s", content: [], surface: .glassesHUD) {}
        let released = Locked(false)
        let ending = Task {
            await gate.end(token, after: runner)
            released.mutate { $0 = true }
        }
        // El stream terminó pero el productor no: la compuerta sigue tomada.
        for _ in 0..<20 { await Task.yield() }
        #expect(!released.value)
        #expect(gate.current == .glassesHUD)
        runner.finishProducer()
        await ending.value
        let next = gate.begin(.siri)               // justo después: libre, siempre
        #expect(next != nil)
        if let next { gate.end(next) }
    }

    @Test func elLoopEsperaAlProductorAunqueElConsumidorCorte() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let finished = Locked(false)
        let loop = AgentLoop(provider: SlowProvider(finished: finished), store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [], serverTools: [], sleep: { _ in })
        let sid = try store.startSession()
        let consumer = Task {
            for await event in await loop.run(sessionId: sid, content: [.text("hola")], surface: .siri) {
                if case .textDelta = event { return }
            }
        }
        await consumer.value
        let gate = TurnGate()
        let siri = try #require(gate.begin(.siri))
        // El consumidor cortó: el loop cancela su turno, pero la compuerta
        // espera a que la tarea del turno de verdad termine.
        await gate.end(siri, after: loop)
        #expect(await loop.turnsInFlight == 0)
        #expect(gate.current == nil)
    }
}

@Suite("Review #38 ronda 3 — voz: una sola regla de oraciones y puntuación limpia")
struct SpeechRound3Tests {
    // Menor 2: la voz en vivo de las gafas usa la MISMA regla que HUDSummary.
    @Test func laVozEnVivoNoParteAbreviaturas() {
        var segmenter = StreamingSentenceSegmenter()
        var said: [String] = []
        for delta in ["Habla con el Sr. ", "Pérez a las 4 p. ", "m. Luego ", "descansa."] {
            said += segmenter.feed(delta)
        }
        said += segmenter.finish()
        #expect(said == ["Habla con el Sr. Pérez a las 4 p. m.", "Luego descansa."])
        #expect(said == HUDSummary.sentences("Habla con el Sr. Pérez a las 4 p. m. Luego descansa."))
    }

    // Menor 3: letras sueltas cortan; "p. m."/"a. m." como patrón; abreviaturas comunes.
    @Test func abreviaturasAfinadas() {
        #expect(HUDSummary.sentences("Opción a. Opción b.") == ["Opción a.", "Opción b."])
        #expect(HUDSummary.sentences("Ve al apto. 302. Sube.") == ["Ve al apto. 302.", "Sube."])
        #expect(HUDSummary.sentences("Son aprox. diez. Listo.") == ["Son aprox. diez.", "Listo."])
        #expect(HUDSummary.sentences("Lleva pan, leche, etc. y vuelve. Gracias.")
            == ["Lleva pan, leche, etc. y vuelve.", "Gracias."])
        #expect(HUDSummary.sentences("Compra frutas, etc. Mañana sigo.") == ["Compra frutas, etc.", "Mañana sigo."])
        #expect(HUDSummary.sentences("Sale a las 9 a. m. y vuelve.") == ["Sale a las 9 a. m. y vuelve."])
        #expect(HUDSummary.sentences("Llama al núm. 3 del tel. 555. Ok.") == ["Llama al núm. 3 del tel. 555.", "Ok."])
        #expect(HUDSummary.sentences("Vive en la Av. Bolívar. Ve.") == ["Vive en la Av. Bolívar.", "Ve."])
        #expect(HUDSummary.sentences("Usa algo, p. ej. una lista. Bien.") == ["Usa algo, p. ej. una lista.", "Bien."])
        #expect(HUDSummary.sentences("A las 3 p.m. Luego.") == ["A las 3 p.m.", "Luego."])
        // Al final del texto, una abreviatura condicional cierra la frase.
        #expect(HUDSummary.sentences("Termina a las 5 p. m.") == ["Termina a las 5 p. m."])
    }

    // Menor 6: sin espacios sueltos antes de la puntuación; ™ y © se quedan.
    @Test func puntuacionLimpiaYSimbolosDeTexto() {
        #expect(SiriTurn.spoken(.replied("Tienes 3 reuniones 📅. ¡Ánimo 💪!")) == "Tienes 3 reuniones. ¡Ánimo!")
        #expect(SiriTurn.spoken(.replied("Anima™ y © 2026 ✅ , listo ⚠️ ; ok")) == "Anima™ y © 2026, listo; ok")
    }
}
