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
            Task {
                started.mutate { $0 = true }
                for await _ in wait {}
                for e in events { c.yield(e) }
                c.finish()
            }
        }
    }
}

/// Lo que el runner entrega y avisa (espejo y cierre).
final class SiriSpy: @unchecked Sendable {
    let delivered = Locked<[SurfaceContent]>([])
    let settled = Locked<[SiriTurn.Outcome?]>([])
    let declines = Locked(0)
    let pending = Locked<String?>(nil)

    func runner(_ runner: any TurnRunner, deadline: Duration = .seconds(5)) -> SiriTurnRunner {
        SiriTurnRunner(runner: runner, sessionId: "s1", deadline: deadline, pollInterval: .milliseconds(5),
                       pendingApproval: { self.pending.value },
                       declineApproval: { self.declines.mutate { $0 += 1 }; self.pending.mutate { $0 = nil } },
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
        #expect(SiriTurn.lateNotice(.replied("Listo: tu semana está libre.")) == "Listo: tu semana está libre.")
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
        #expect(spy.delivered.value.last == .status("Sin conexión con el modelo."))
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

    @Test func confirmacionPendienteSePreguntaYLuegoSigue() async {
        let runner = SiriGatedRunner([.textDelta("Creé el evento."), .turnFinished(stopReason: .endTurn)], gated: true)
        let spy = SiriSpy()
        let siri = spy.runner(runner)
        Task {
            for _ in 0..<400 where !runner.started.value { try? await Task.sleep(for: .milliseconds(2)) }
            spy.pending.mutate { $0 = "crear evento 'Reunión' mañana 9:00" }
        }
        let first = await siri.ask("agéndame la reunión")
        #expect(first == .needsApproval("crear evento 'Reunión' mañana 9:00"))
        #expect(SiriTurn.confirmationPrompt("crear evento 'Reunión' mañana 9:00")
            == "Para eso necesito tu ok: crear evento 'Reunión' mañana 9:00. ¿Lo hago?")
        #expect(SiriTurn.spoken(first).contains("confirmación"))
        // El dueño aprobó por Siri: la app resuelve y el turno sigue.
        spy.pending.mutate { $0 = nil }
        runner.open()
        #expect(await siri.resume() == .replied("Creé el evento."))
        await siri.release()
        await spy.waitSettled()
        #expect(spy.settled.value == [nil])
        #expect(spy.declines.value == 0)
    }

    @Test func trasSoltarSiriUnaConfirmacionNuevaSeCancela() async {
        let runner = SiriGatedRunner([.textDelta("No lo hice: lo cancelaste."), .turnFinished(stopReason: .endTurn)],
                                 gated: true)
        let spy = SiriSpy()
        let siri = spy.runner(runner, deadline: .milliseconds(30))
        #expect(await siri.ask("borra mi recordatorio") == .deferred)
        await siri.release()
        spy.pending.mutate { $0 = "borrar recordatorio" }
        for _ in 0..<400 where spy.declines.value == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(spy.declines.value == 1)   // fail-closed: nadie puede darla
        runner.open()
        await spy.waitSettled()
        #expect(spy.settled.value == [.replied("No lo hice: lo cancelaste.")])
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
