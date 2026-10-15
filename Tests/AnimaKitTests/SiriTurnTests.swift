import Foundation
import Testing
@testable import AnimaKit

/// Runner con compuerta: emite `events` y no cierra el turno hasta `open()`.
final class SiriGatedRunner: TurnRunner, @unchecked Sendable {
    let events: [LoopEvent]
    let received = Locked<[(content: [ContentBlock], surface: SurfaceID)]>([])
    let started = Locked(false)
    private let gate = Locked<AsyncStream<Void>.Continuation?>(nil)
    private let gated: Bool

    init(_ events: [LoopEvent], gated: Bool = false) {
        self.events = events
        self.gated = gated
    }

    func open() { gate.mutate { $0?.finish(); $0 = nil } }

    func run(sessionId: SessionID, content: [ContentBlock], surface: SurfaceID) async -> AsyncStream<LoopEvent> {
        received.mutate { $0.append((content, surface)) }
        let (wait, signal) = AsyncStream<Void>.makeStream()
        if gated { gate.mutate { $0 = signal } } else { signal.finish() }
        let events = self.events
        let started = self.started
        return AsyncStream { c in
            let task = Task {
                started.mutate { $0 = true }
                for await _ in wait {}
                for e in events { c.yield(e) }
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

/// Runner cuya tool pide `asks` confirmaciones por el router (como el
/// Sensorimotor de un turno de Siri) y responde según lo decidido.
final class SiriApprovalRunner: TurnRunner, @unchecked Sendable {
    let router: SurfaceConfirmationRouter
    let asks: Int
    let decisions = Locked<[Bool]>([])

    init(router: SurfaceConfirmationRouter, asks: Int = 1) {
        self.router = router
        self.asks = asks
    }

    func run(sessionId: SessionID, content: [ContentBlock], surface: SurfaceID) async -> AsyncStream<LoopEvent> {
        let router = self.router, asks = self.asks, decisions = self.decisions
        return AsyncStream { c in
            Task {
                for i in 0..<asks {
                    let ok = await router.confirm(ConfirmationRequest(
                        tool: "calendar", operation: "create", summary: "crear evento \(i + 1)", input: .null,
                        surface: surface))
                    decisions.mutate { $0.append(ok) }
                }
                c.yield(.textDelta(decisions.value.allSatisfy { $0 } ? "Creé el evento." : "No lo hice: no lo confirmaste."))
                c.finish()
            }
        }
    }
}

struct AskingPhone: ConfirmationProvider {
    let asked: Locked<[String]>
    func confirm(_ request: ConfirmationRequest) async -> Bool {
        asked.mutate { $0.append(request.summary) }
        return true
    }
}

/// Lo que el runner entrega y avisa (espejo y cierre).
final class SiriSpy: @unchecked Sendable {
    let delivered = Locked<[SurfaceContent]>([])
    let settled = Locked<[SiriTurn.Outcome?]>([])
    let approvals = SiriApprovals()

    func runner(_ runner: any TurnRunner, deadline: Duration = .seconds(5),
                hardLimit: Duration = .seconds(60)) -> SiriTurnRunner {
        SiriTurnRunner(runner: runner, sessionId: "s1", approvals: approvals, deadline: deadline,
                       hardLimit: hardLimit, pollInterval: .milliseconds(5),
                       deliver: { content in self.delivered.mutate { $0.append(content) } },
                       settled: { late in self.settled.mutate { $0.append(late) } })
    }

    func waitSettled() async {
        for _ in 0..<400 where settled.value.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

@Suite("Batch 10 #2 — hablar con Anima por Siri")
struct SiriTurnTests {
    @Test func respondeYQuedaEnElChatComoTurnoDeSiri() async {
        let runner = SiriGatedRunner([.textDelta("Mañana tienes "), .textDelta("el standup a las 9."),
                                  .assistantMessage([.text("Mañana tienes el standup a las 9.")]),
                                  .turnFinished(stopReason: .endTurn)])
        let spy = SiriSpy()
        let siri = spy.runner(runner)
        let outcome = await siri.ask("  ¿qué tengo mañana? ")
        #expect(outcome == .replied("Mañana tienes el standup a las 9."))
        #expect(SiriTurn.spoken(outcome) == "Mañana tienes el standup a las 9.")
        #expect(runner.received.value.map(\.surface) == [.siri])
        #expect(runner.received.value.first?.content == [AudioTool.transcriptBlock("¿qué tengo mañana?")])
        #expect(spy.delivered.value == [.userTurn(text: "¿qué tengo mañana?", origin: .siri),
                                        .assistantTurn(text: "Mañana tienes el standup a las 9.", origin: .siri)])
        await siri.release()
        await spy.waitSettled()
        #expect(spy.settled.value == [nil])   // ya lo oyó: sin aviso
    }

    @Test func pasadoElDeadlineDiceTeRespondoEnElChatYAvisaAlLlegar() async {
        let runner = SiriGatedRunner([.textDelta("Listo: tu semana está libre."), .turnFinished(stopReason: .endTurn)],
                                 gated: true)
        let spy = SiriSpy()
        let siri = spy.runner(runner, deadline: .milliseconds(40))
        let outcome = await siri.ask("¿cómo está mi semana?")
        #expect(outcome == .deferred)
        #expect(SiriTurn.spoken(outcome) == "Te respondo en el chat.")
        await siri.release()
        #expect(spy.settled.value.isEmpty)
        runner.open()
        await spy.waitSettled()
        #expect(spy.settled.value == [.replied("Listo: tu semana está libre.")])
        #expect(spy.delivered.value.last == .assistantTurn(text: "Listo: tu semana está libre.", origin: .siri))
        // Me4: el aviso tardío es genérico (nada de la respuesta en la pantalla bloqueada).
        #expect(SiriTurn.lateNotice(.replied("Listo: tu semana está libre.")) == SiriTurn.lateNoticeText)
    }

    @Test func nuncaAfirmaLoRetraidoYDiceElFallo() async {
        let notice = "⚠️ No pude crear el evento: sin permiso de calendario."
        let runner = SiriGatedRunner([.textDelta("Listo, lo agendé."), .retracted,
                                  .textDelta("Lo intenté pero no se pudo."), .toolFailure(notice),
                                  .turnFinished(stopReason: .endTurn)])
        let spy = SiriSpy()
        let outcome = await spy.runner(runner).ask("agéndame la reunión")
        guard case .replied(let text) = outcome else {
            Issue.record("esperaba respuesta: \(outcome)")
            return
        }
        #expect(text.hasPrefix(notice))
        #expect(!text.contains("lo agendé"))
        let spoken = SiriTurn.spoken(outcome)
        #expect(spoken.hasPrefix("No pude crear el evento"))
        #expect(!spoken.contains("⚠️"))
    }

    @Test func errorSinRespuestaSeDiceComoError() async {
        let spy = SiriSpy()
        let outcome = await spy.runner(SiriGatedRunner([.error("Sin conexión con el modelo.")])).ask("hola")
        #expect(outcome == .failed("Sin conexión con el modelo."))
        #expect(SiriTurn.spoken(outcome) == "No pude responderte: Sin conexión con el modelo.")
        #expect(spy.delivered.value.last == .turnFailed(text: "Sin conexión con el modelo.", origin: .siri))
        let stopped = await SiriSpy().runner(SiriGatedRunner([.stopped(.maxIterations)])).ask("hola")
        guard case .failed(let reason) = stopped else {
            Issue.record("esperaba fallo: \(stopped)")
            return
        }
        #expect(reason.hasPrefix("Turno detenido"))
        #expect(SiriTurn.lateNotice(stopped)?.contains("chat") == true)
    }

    @Test func rechazoSinTextoUsaLaFraseAmable() async {
        let spy = SiriSpy()
        let outcome = await spy.runner(SiriGatedRunner([.refused])).ask("algo raro")
        #expect(outcome == .declined(SiriTurn.declinedDefault))
        #expect(spy.delivered.value.last == .declined(text: SiriTurn.declinedDefault, origin: .siri))
    }

    @Test func textoVacioNoCorreTurnoYCierra() async {
        let runner = SiriGatedRunner([])
        let spy = SiriSpy()
        let siri = spy.runner(runner)
        #expect(await siri.ask("   ") == .empty)
        #expect(runner.received.value.isEmpty)
        #expect(spy.settled.value == [nil])
        #expect(SiriTurn.spoken(.empty) == SiriTurn.emptyText)
        #expect(await siri.resume() == .failed("No había un turno en curso."))
    }

    @Test func unSoloTurnoPorRunner() async {
        let siri = SiriSpy().runner(SiriGatedRunner([.textDelta("ok")]))
        _ = await siri.ask("uno")
        #expect(await siri.ask("dos") == .busy)
    }

    @Test func laRespuestaHabladaSeAcotaYRemiteAlChat() {
        let long = "## Tu plan\n\n" + (1...12).map { "**Paso \($0)**: haz algo concreto con calma." }.joined(separator: " ")
        let spoken = SiriTurn.spoken(.replied(long))
        #expect(spoken.count <= SiriTurn.spokenLimit + SiriTurn.chatTail.count + 1)
        #expect(spoken.hasSuffix(SiriTurn.chatTail))
        #expect(!spoken.contains("#"))
        #expect(!spoken.contains("**"))
        let noSentences = String(repeating: "palabra ", count: 80)
        #expect(SiriTurn.spoken(.replied(noSentences)).hasSuffix(SiriTurn.chatTail))
        #expect(SiriTurn.spoken(.busy) == SiriTurn.busyText)
        #expect(SiriTurn.spoken(.offline) == SiriTurn.offlineText)
        #expect(SiriTurn.spoken(.notReady("Abre Anima para terminar de configurarla.")) == "Abre Anima para terminar de configurarla.")
        #expect(SiriTurn.lateNotice(.deferred) == nil)
    }

    @MainActor
    @Test func turnoDeSiriPersisteConSuMarcaYPistaDeVoz() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let provider = CapturingProvider([.text("Claro."), .text("Por el teléfono.")])
        let loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [], serverTools: [], sleep: { _ in })
        let sid = try store.startSession()
        let outcome = await SiriTurnRunner(runner: loop, sessionId: sid).ask("recuérdame el agua")
        #expect(outcome == .replied("Claro."))
        for await _ in await loop.run(sessionId: sid, userText: "hola") {}
        #expect(try store.surfaces(sessionId: sid) == [.siri, .siri, .phoneChat, .phoneChat])
        let hints = provider.captures.value.map { capture in
            capture.messages.contains { $0.role == .system && $0.content == [.text(AgentLoop.siriSurfaceHint)] }
        }
        #expect(hints == [true, false])
        let history = ChatViewModel.history(turns: try store.historyPage().turns, boundaries: [:])
        let owner = history.filter { $0.role == .user }
        #expect(owner.first?.text == "recuérdame el agua")
        #expect(owner.first?.channelChip?.label == "Siri")
        #expect(owner.last?.channelChip == nil)
    }

    @Test func superficieSiriNoTienePantallaNiBotones() {
        #expect(SurfaceCapabilities.siri.maxButtons == 0)
        #expect(SurfaceCapabilities.siri.audioOut)
        #expect(!SurfaceCapabilities.siri.images)
        #expect(SurfaceID(rawValue: "siri") == .siri)
        #expect(AgentLoop.surfaceHint(.phoneChat) == nil)
        #expect(AgentLoop.surfaceHint(.glassesHUD) == AgentLoop.glassesSurfaceHint)
    }
}

@Suite("Review #38 — Siri: confirmaciones propias, un turno a la vez, voz y honestidad")
struct SiriReviewTests {
    private func router(_ approvals: SiriApprovals, phone: Locked<[String]>) -> SurfaceConfirmationRouter {
        SurfaceConfirmationRouter(phone: AskingPhone(asked: phone), glasses: nil, siri: approvals)
    }

    // M1: un mensaje vacío no deja nada vivo que cancele aprobaciones futuras.
    @Test func mensajeVacioNoCancelaAprobacionesFuturas() async {
        let spy = SiriSpy()
        let siri = spy.runner(SiriGatedRunner([]))
        #expect(await siri.ask("   ") == .empty)
        await siri.release()
        let phone = Locked<[String]>([])
        let chatAsk = ConfirmationRequest(tool: "calendar", operation: "create", summary: "Crear evento del chat",
                                          input: .null, surface: .phoneChat)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await router(spy.approvals, phone: phone).confirm(chatAsk))
        #expect(phone.value == ["Crear evento del chat"])
    }

    // Me1: tras soltar Siri, las confirmaciones del chat y las gafas siguen yendo
    // a su dueño; solo las de Siri se niegan.
    @Test func siriSoloResuelveLasSuyas() async {
        let spy = SiriSpy()
        let siri = spy.runner(SiriGatedRunner([.textDelta("ok")], gated: true), deadline: .milliseconds(20))
        #expect(await siri.ask("algo largo") == .deferred)
        await siri.release()
        let phone = Locked<[String]>([])
        let route = router(spy.approvals, phone: phone)
        #expect(await route.confirm(ConfirmationRequest(tool: "calendar", operation: "create", summary: "del chat",
                                                        input: .null, surface: .phoneChat)))
        #expect(await route.confirm(ConfirmationRequest(tool: "reminders", operation: "create", summary: "de gafas",
                                                        input: .null, surface: .glassesHUD)))
        #expect(phone.value == ["del chat", "de gafas"])
        #expect(await route.confirm(ConfirmationRequest(tool: "calendar", operation: "create", summary: "de siri",
                                                        input: .null, surface: .siri)) == false)
        // Sin buzón de Siri cableado: fail-closed.
        #expect(await SurfaceConfirmationRouter(phone: AskingPhone(asked: phone), glasses: nil)
            .confirm(ConfirmationRequest(tool: "x", operation: "y", summary: "z", input: .null, surface: .siri)) == false)
    }

    @Test func confirmacionPorSiriSePreguntaYLuegoSigue() async {
        let spy = SiriSpy()
        let phone = Locked<[String]>([])
        let runner = SiriApprovalRunner(router: router(spy.approvals, phone: phone))
        let siri = spy.runner(runner)
        let first = await siri.ask("agéndame la reunión")
        #expect(first == .needsApproval("crear evento 1"))
        spy.approvals.resolve(true)
        #expect(await siri.resume() == .replied("Creé el evento."))
        #expect(phone.value.isEmpty)   // jamás pasó por el sheet del teléfono
        await siri.release()
        await spy.waitSettled()
        #expect(spy.settled.value == [nil])
    }

    // Menor: con más aprobaciones de las que Siri pregunta, lo dicho es verdad:
    // al soltar, la pendiente se niega y Siri dice que no lo hizo.
    @Test func siYaNoPreguntaDiceQueNoLoHizo() async {
        let spy = SiriSpy()
        let phone = Locked<[String]>([])
        let runner = SiriApprovalRunner(router: router(spy.approvals, phone: phone), asks: 2)
        let siri = spy.runner(runner)
        let outcome = await siri.ask("agenda dos cosas")
        #expect(outcome == .needsApproval("crear evento 1"))
        await siri.release()
        await spy.waitSettled()
        #expect(runner.decisions.value == [false, false])
        #expect(spy.settled.value == [.replied("No lo hice: no lo confirmaste.")])
        let spoken = SiriTurn.spoken(outcome)
        #expect(spoken.contains("no lo hice"))
        #expect(!spoken.contains("Ábrelo"))
    }

    // Me2: un turno a la vez sobre la sesión (Siri, chat y gafas).
    @Test func compuertaDeTurnoUnoALaVez() async {
        let gate = TurnGate()
        let seen = Locked<[SurfaceID?]>([])
        gate.observe { holder in seen.mutate { $0.append(holder) } }
        let siri = try? #require(gate.begin(.siri))
        #expect(gate.begin(.siri) == nil)
        #expect(gate.begin(.phoneChat) == nil)
        gate.end(TurnGate.Token(surface: .siri))   // un token ajeno (aunque sea de Siri) no la suelta
        #expect(gate.current == .siri)
        if let siri { gate.end(siri) }
        #expect(gate.current == nil)
        #expect(seen.value == [.siri, nil])
        #expect(SiriTurn.spoken(.busy) == SiriTurn.busyText)
        #expect(TurnGate.busyText(.siri).contains("Siri"))
        #expect(TurnGate.busyText(.glassesHUD).contains("gafas"))
        #expect(TurnGate.busyText(.phoneChat).contains("otra respuesta"))
    }

    // Me3: la voz no rompe números, horas, abreviaturas ni URLs.
    @Test func lasOracionesNoCortanNumerosNiAbreviaturas() {
        #expect(HUDSummary.sentences("El vuelo cuesta 1.250.000 pesos y sale a las 3.30. Llega temprano.")
            == ["El vuelo cuesta 1.250.000 pesos y sale a las 3.30.", "Llega temprano."])
        #expect(HUDSummary.sentences("Habla con el Sr. Pérez a las 4 p. m. Luego descansa.")
            == ["Habla con el Sr. Pérez a las 4 p. m.", "Luego descansa."])
        #expect(HUDSummary.sentences("Míralo en anima.app/ayuda. ¿Listo?!") == ["Míralo en anima.app/ayuda.", "¿Listo?!"])
        #expect(HUDSummary.sentences("Espera... ya.") == ["Espera...", "ya."])
        let long = "El vuelo cuesta 1.250.000 pesos y sale a las 3.30 desde el terminal 2. "
            + String(repeating: "Lleva el pasaporte y llega con tiempo de sobra al aeropuerto. ", count: 5)
        let siri = SiriTurn.spoken(.replied(long))
        #expect(siri.hasPrefix("El vuelo cuesta 1.250.000 pesos y sale a las 3.30 desde el terminal 2."))
        #expect(siri.hasSuffix(SiriTurn.chatTail))
        let glasses = HUDSummary.spoken(from: long)
        #expect(glasses.hasPrefix("El vuelo cuesta 1.250.000 pesos y sale a las 3.30 desde el terminal 2."))
        #expect(glasses.hasSuffix(HUDSummary.phoneTail))
    }

    // Menor: un error (o una parada) después de texto a medias se dice como fallo.
    @Test func errorTrasTextoParcialEsFallo() async {
        let partial = await SiriSpy().runner(SiriGatedRunner([.textDelta("Voy a revisar tu agenda y"),
                                                              .error("Sin conexión")])).ask("¿qué tengo?")
        #expect(partial == .failed("Sin conexión"))
        #expect(SiriTurn.spoken(partial) == "No pude responderte: Sin conexión")
        let stopped = await SiriSpy().runner(SiriGatedRunner([.textDelta("Empiezo"), .stopped(.loopDetected)]))
            .ask("hazlo")
        guard case .failed(let reason) = stopped else {
            Issue.record("esperaba fallo: \(stopped)")
            return
        }
        #expect(reason.hasPrefix("Turno detenido"))
    }

    // Menor: la voz no lee emojis ni pictogramas.
    @Test func laVozNoLeeEmojis() {
        let spoken = SiriTurn.spoken(.replied("⚠️ No pude 📅 agendarlo 👍🏽 Te aviso ✅ mañana #1 a las 9*"))
        #expect(spoken == "No pude agendarlo Te aviso mañana #1 a las 9*")
        #expect(SiriTurn.spoken(.failed("❌ Sin red 🌐")) == "No pude responderte: Sin red")
    }

    // Menor: Híbrido conversa en el remoto (el modelo local es solo para el
    // sueño y el pulso), así que sin red Siri dice lo mismo que hace el chat.
    @Test func sinRedLaMismaReglaQueElChat() {
        #expect(OperatingMode.hybrid.conversationNeedsNetwork)
        #expect(OperatingMode.remote.conversationNeedsNetwork)
        #expect(!OperatingMode.onDeviceOnly.conversationNeedsNetwork)
    }

    // Menor: un provider que nunca termina no retiene la base: el tope duro
    // corta el turno y lo cierra como fallo.
    @Test func elTopeDuroCortaUnTurnoColgado() async {
        let spy = SiriSpy()
        let runner = SiriGatedRunner([.textDelta("nunca")], gated: true)
        let siri = spy.runner(runner, deadline: .milliseconds(20), hardLimit: .milliseconds(60))
        #expect(await siri.ask("hola") == .deferred)
        await siri.release()
        await spy.waitSettled()
        #expect(spy.settled.value == [.failed(SiriTurn.timeoutText)])
        #expect(spy.delivered.value.last == .turnFailed(text: SiriTurn.timeoutText, origin: .siri))
    }

    @Test func cancelarExplicitoTambienCierra() async {
        let spy = SiriSpy()
        let siri = spy.runner(SiriGatedRunner([.textDelta("x")], gated: true), deadline: .milliseconds(20))
        #expect(await siri.ask("hola") == .deferred)
        await siri.cancel()
        await siri.release()
        await spy.waitSettled()
        #expect(spy.settled.value == [.failed(SiriTurn.timeoutText)])
    }
}

@MainActor
@Suite("Review #38 — el chat ve ocupado el turno de otra superficie y muestra su error")
struct MirroredTurnChatTests {
    private func chat() throws -> ChatViewModel {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        return ChatViewModel(loop: try FullHistoryStoreTests.loop(store, queue), sessionId: try store.startSession())
    }

    @Test func turnoDeSiriOcupaElChatHastaLaRespuesta() async throws {
        let chat = try chat()
        await chat.render(.userTurn(text: "¿qué tengo?", origin: .siri))
        #expect(chat.isStreaming)
        #expect(chat.messages.last?.isStreaming == true)
        #expect(chat.messages.first?.channelChip?.label == "Siri")
        await chat.render(.assistantTurn(text: "Nada hoy.", origin: .siri))
        #expect(!chat.isStreaming)
        #expect(chat.messages.count == 2)
        #expect(chat.messages.last?.text == "Nada hoy.")
        #expect(chat.lastMirroredTurnID == chat.messages.last?.id)
    }

    @Test func elFalloDeSiriLlegaAlChat() async throws {
        let chat = try chat()
        await chat.render(.userTurn(text: "hola", origin: .siri))
        await chat.render(.turnFailed(text: "Sin conexión", origin: .siri))
        #expect(!chat.isStreaming)
        #expect(chat.messages.count == 2)
        #expect(chat.messages.last?.isError == true)
        #expect(chat.messages.last?.text == "Sin conexión")
        // Un status genérico no cierra ni pinta nada.
        await chat.render(.status("otro"))
        #expect(chat.messages.count == 2)
        await chat.render(.userTurn(text: "algo raro", origin: .glassesHUD))
        await chat.render(.declined(text: "Prefiero no.", origin: .glassesHUD))
        #expect(chat.messages.last?.isRefusal == true)
        #expect(!chat.isStreaming)
    }

    // Menor 1: con la compuerta tomada el mensaje no se pierde: el composer no
    // envía (y conserva el texto); si ya iba en camino, queda pendiente y sale
    // al liberarse la compuerta.
    @Test func conLaCompuertaTomadaElMensajeNoSePierde() async throws {
        let chat = try chat()
        let gate = TurnGate()
        chat.turnGate = gate
        let siri = try #require(gate.begin(.siri))
        #expect(chat.isStreaming)   // derivado de la compuerta
        chat.input = "hola"
        await chat.send()
        #expect(chat.input == "hola")
        #expect(chat.messages.isEmpty)
        gate.end(siri)
        for _ in 0..<200 where chat.isStreaming { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!chat.isStreaming)
    }

    @Test func loEncoladoEsperaLaCompuertaYSaleAlLiberarse() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let provider = CapturingProvider([[.messageStart(id: "m", model: "x"), .textDelta("Hola."), .messageStop]])
        let loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [], serverTools: [], sleep: { _ in })
        let chat = ChatViewModel(loop: loop, sessionId: try store.startSession())
        let gate = TurnGate()
        chat.turnGate = gate
        chat.usesRemoteConversation = true
        await chat.setOffline(true)
        chat.input = "hola"
        await chat.send()
        #expect(chat.hasQueuedTurn)
        // Vuelve la red con otra superficie respondiendo: sigue encolado (no se pierde).
        let siri = try #require(gate.begin(.siri))
        await chat.setOffline(false)
        #expect(chat.hasQueuedTurn)
        #expect(provider.captures.value.isEmpty)
        // Se libera la compuerta: sale solo.
        gate.end(siri)
        for _ in 0..<400 where chat.hasQueuedTurn || chat.isStreaming { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!chat.hasQueuedTurn)
        #expect(provider.captures.value.count == 1)
        #expect(gate.current == nil)
    }
}
