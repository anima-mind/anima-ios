import Foundation
import Testing
@testable import AnimaKit

// MARK: - Dobles del carro

/// Bitácora compartida: el orden entre audio y voz es parte del contrato.
final class CarLog: @unchecked Sendable {
    let entries = Locked<[String]>([])
    func add(_ entry: String) { entries.mutate { $0.append(entry) } }
    var spoken: [String] { entries.value.compactMap { $0.hasPrefix("say:") ? String($0.dropFirst(4)) : nil } }
}

/// Micrófono guionado: cada captura devuelve el siguiente transcript. Con
/// `holdOpen`, la captura espera a `finish` (Listo) o `cancel`.
final class CarVoice: VoiceCapturePort, @unchecked Sendable {
    let transcripts = Locked<[String?]>([])
    let failure = Locked<VoiceCaptureFailure?>(nil)
    let holdOpen = Locked(false)
    /// Solo retiene desde la captura N (1 = la primera): p. ej. 2 = la respuesta a "¿Lo hago?".
    let holdFrom = Locked<Int?>(nil)
    let captures = Locked(0)
    let cancels = Locked(0)
    let finishes = Locked(0)
    private let released = Locked(false)
    let log: CarLog

    init(_ transcripts: [String?] = [], log: CarLog) {
        self.transcripts.mutate { $0 = transcripts }
        self.log = log
    }

    func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void) async -> String? {
        await capture(onRoute: onRoute, onPartial: { _ in }, onFailure: { _ in })
    }

    func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void,
                 onPartial: @escaping @Sendable (String) -> Void,
                 onFailure: @escaping @Sendable (VoiceCaptureFailure) -> Void) async -> String? {
        let index = captures.mutate { $0 += 1; return $0 }
        log.add("listen")
        if let reason = failure.value { onFailure(reason); return nil }
        if holdOpen.value || holdFrom.value.map({ index >= $0 }) == true {
            // Un Listo/cancelar que llegó antes de arrancar cuenta (se consume aquí).
            while !released.value { try? await Task.sleep(for: .milliseconds(2)) }
            released.mutate { $0 = false }
        }
        return transcripts.mutate { $0.isEmpty ? nil : $0.removeFirst() }
    }

    func cancel() {
        cancels.mutate { $0 += 1 }
        transcripts.mutate { $0 = [] }
        released.mutate { $0 = true }
    }

    func finish() {
        finishes.mutate { $0 += 1 }
        released.mutate { $0 = true }
    }
}

/// TTS guionado: anota cada utterance; con `gated`, no termina hasta `release()` o `stop()`.
final class CarSpeaker: SpeechOutputPort, @unchecked Sendable {
    let log: CarLog
    let gated = Locked(false)
    let stops = Locked(0)
    private let open = Locked(false)

    init(log: CarLog) { self.log = log }

    /// Demora entre el despacho y el arranque del audio (un runner lento).
    let startLag = Locked<Duration?>(nil)
    /// Control negativo: ignora la línea (como antes del fix).
    let ignoresLine = Locked(false)

    func speak(_ text: String) async {
        start(text)
        await hold()
    }

    /// Como el sintetizador real: el arranque ("say:") ocurre DENTRO de
    /// `line.perform`, así un corte (invalidate) no puede colarse en medio.
    func speak(_ text: String, line: SpeechLine, ticket: SpeechLine.Ticket) async {
        if let lag = startLag.value { try? await Task.sleep(for: lag) }
        if ignoresLine.value {
            await speak(text)
            return
        }
        guard line.perform(ticket, { start(text) }) else { return }
        await hold()
    }

    private func start(_ text: String) {
        log.add("say:" + text)
        if gated.value { open.mutate { $0 = false } }
    }

    private func hold() async {
        guard gated.value else { return }
        while !open.value { try? await Task.sleep(for: .milliseconds(2)) }
    }

    func release() { open.mutate { $0 = true } }

    func stop() {
        stops.mutate { $0 += 1 }
        open.mutate { $0 = true }
    }
}

final class CarAudio: CarPlayAudioPort, @unchecked Sendable {
    let log: CarLog
    let fails = Locked(false)
    init(log: CarLog) { self.log = log }
    struct Busy: Error {}
    func activateConversation() throws {
        if fails.value { throw Busy() }
        log.add("audio:on")
    }
    func releaseConversation() { log.add("audio:off") }
}

/// Runner que no deja salir el turno de la cola hasta `open()` (sin `.started`).
final class QueuedRunner: TurnRunner, @unchecked Sendable {
    private let gate = Locked(false)
    func open() { gate.mutate { $0 = true } }
    func run(sessionId: SessionID, content: [ContentBlock], surface: SurfaceID) async -> AsyncStream<LoopEvent> {
        let gate = self.gate
        return AsyncStream { c in
            let task = Task {
                while !gate.value, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
                if !Task.isCancelled { c.yield(.started) }
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

/// Runner cuya tool pide el ok por el router (como el Sensorimotor) y responde según lo decidido.
final class CarApprovalRunner: TurnRunner, @unchecked Sendable {
    let router: SurfaceConfirmationRouter
    let request: ConfirmationRequest
    let decisions = Locked<[Bool]>([])

    init(router: SurfaceConfirmationRouter, tool: String = "calendar", operation: String = "create",
         summary: String = "Crear evento 'Dentista' el jueves 15:00") {
        self.router = router
        self.request = ConfirmationRequest(tool: tool, operation: operation, summary: summary, input: .null)
    }

    func run(sessionId: SessionID, content: [ContentBlock], surface: SurfaceID) async -> AsyncStream<LoopEvent> {
        let router = self.router, decisions = self.decisions
        var asked = self.request
        asked.surface = surface
        let request = asked
        return AsyncStream { c in
            let task = Task {
                c.yield(.started)
                c.yield(.textDelta("Claro, lo agendo. "))
                let ok = await router.confirm(request)
                decisions.mutate { $0.append(ok) }
                c.yield(.textDelta(ok ? "Listo, quedó en tu agenda." : "No lo agendé."))
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
final class CarRig {
    let log = CarLog()
    let voice: CarVoice
    let speaker: CarSpeaker
    let audio: CarAudio
    let gate = TurnGate()
    let approvals = CarPlayApprovals()
    let router = SurfaceRouter()
    let phone = FakePhone()
    var phases: [CarPlayPhase] = []
    var pending: [[String]] = []
    var readiness: CarPlayConversation.Readiness
    private(set) var conversation: CarPlayConversation!

    init(runner: any TurnRunner, heard: [String?] = ["¿qué tengo mañana?"],
         confirmTimeout: Duration = .seconds(5), ready: CarPlayConversation.Readiness? = nil) {
        voice = CarVoice(heard, log: log)
        speaker = CarSpeaker(log: log)
        audio = CarAudio(log: log)
        readiness = ready ?? .ready(runner: runner, sessionId: "s1")
        router.register(phone)
        conversation = CarPlayConversation(
            readiness: { [weak self] in self?.readiness ?? .blocked("sin rig") }, gate: gate, gateRetry: .milliseconds(30),
            voice: voice, speech: speaker, audio: audio, approvals: approvals, router: router,
            confirmTimeout: confirmTimeout,
            onPending: { [weak self] in self?.pending.append($0) },
            onPhase: { [weak self] in self?.phases.append($0) })
    }

    func confirmRouter() -> SurfaceConfirmationRouter {
        SurfaceConfirmationRouter(phone: FailClosedConfirmation(), glasses: nil, carplay: approvals)
    }

    /// Espera a que la interacción termine (vuelve al reposo).
    /// Con tope holgado: la suite completa corre en paralelo (coverage-gate).
    func settle(_ timeout: Duration = .seconds(15)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        try? await Task.sleep(for: .milliseconds(5))
        while conversation.isBusy, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
    }

    func waitFor(_ condition: @MainActor () -> Bool, _ timeout: Duration = .seconds(15)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
    }
}

// MARK: - Turno completo

@MainActor
@Suite("CarPlay — conversación por voz en el carro")
struct CarPlayConversationTests {
    @Test func hablaEscuchaRespondeEnVozYQuedaEnElChat() async {
        let runner = MockRunner()
        runner.replies.mutate { $0 = [[.textDelta("Mañana tienes el standup a las 9.30. Des"),
                                       .textDelta("pués almuerzas con Ana."),
                                       .turnFinished(stopReason: .endTurn)]] }
        let rig = CarRig(runner: runner)
        rig.conversation.talk()
        await rig.settle()
        #expect(runner.received.value.map(\.surface) == [.carplay])
        #expect(runner.received.value.first?.content == [AudioTool.transcriptBlock("¿qué tengo mañana?")])
        // La voz va por oración ("9.30" no corta) y la sesión se toma al escuchar y se suelta al terminar.
        #expect(rig.log.entries.value == ["audio:on", "listen", "say:Mañana tienes el standup a las 9.30.",
                                          "say:Después almuerzas con Ana.", "audio:off"])
        #expect(rig.phone.rendered == [
            .userTurn(text: "¿qué tengo mañana?", origin: .carplay),
            .assistantTurn(text: "Mañana tienes el standup a las 9.30. Después almuerzas con Ana.", origin: .carplay),
        ])
        #expect(rig.phases.first == .listening)
        #expect(rig.phases.contains(.thinking))
        #expect(rig.phases.contains(.speaking))
        #expect(rig.conversation.phase == .idle)
        #expect(!rig.conversation.audioActive)
        #expect(rig.gate.current == nil)
    }

    @Test func respuestaLargaSeAcotaSinMarkdownNiEmojisYRemiteAlChat() async {
        let runner = MockRunner()
        let long = "## Tu semana 🎉\n\n" + (1...12).map { "**Día \($0)**: tienes algo importante que hacer." }
            .joined(separator: " ")
        runner.replies.mutate { $0 = [[.textDelta(long)]] }
        let rig = CarRig(runner: runner)
        rig.conversation.talk()
        await rig.settle()
        let said = rig.log.spoken
        #expect(said.last == CarPlayTurn.chatTail)
        #expect(said.joined(separator: " ").count <= CarPlayTurn.spokenLimit + CarPlayTurn.chatTail.count + 1)
        #expect(!said.joined().contains("#"))
        #expect(!said.joined().contains("**"))
        #expect(!said.joined().contains("🎉"))
    }

    @Test func sinTranscriptDiceQueNoEscuchoYNoCorreTurno() async {
        let runner = MockRunner()
        let rig = CarRig(runner: runner, heard: [nil])
        rig.conversation.talk()
        await rig.settle()
        #expect(runner.received.value.isEmpty)
        #expect(rig.log.entries.value == ["audio:on", "listen", "say:\(CarPlayTurn.emptyText)", "audio:off"])
        #expect(rig.phone.rendered.isEmpty)
    }

    @Test func fallaDelMicrofonoSeDiceSinMandarAlTelefono() async {
        let rig = CarRig(runner: MockRunner())
        rig.voice.failure.mutate { $0 = .microphonePermissionDenied }
        rig.conversation.talk()
        await rig.settle()
        let said = rig.log.spoken
        #expect(said == [CarPlayTurn.voiceFailureText(.microphonePermissionDenied)])
        #expect(!said.joined().contains("iPhone"))
        #expect(CarPlayTurn.voiceFailureText(.engineFailed("x")).contains("micrófono"))
        #expect(CarPlayTurn.voiceFailureText(.recognizerUnavailable("x")).contains("dictado"))
    }

    @Test func noListaDiceElMotivoYNoAbreElMicrofono() async {
        let runner = MockRunner()
        let rig = CarRig(runner: runner, ready: .blocked(CarPlayTurn.offlineText))
        rig.conversation.talk()
        await rig.settle()
        #expect(rig.voice.captures.value == 0)
        #expect(rig.log.entries.value == ["audio:on", "say:\(CarPlayTurn.offlineText)", "audio:off"])
        #expect(runner.received.value.isEmpty)
    }

    @Test func otraSuperficieConElTurnoDiceOcupadoSinEscuchar() async throws {
        let runner = MockRunner()
        let rig = CarRig(runner: runner)
        let siri = try #require(rig.gate.begin(.siri))
        rig.conversation.talk()
        await rig.settle()
        #expect(rig.voice.captures.value == 0)
        #expect(rig.log.spoken == [CarPlayTurn.busyText(.siri)])
        #expect(rig.phone.rendered.isEmpty)
        #expect(runner.received.value.isEmpty)
        rig.gate.end(siri)
        #expect(TurnGate.busyText(.carplay).contains("CarPlay"))
        #expect(CarPlayTurn.busyText(.glassesHUD).contains("gafas"))
        #expect(CarPlayTurn.busyText(.phoneChat) == CarPlayTurn.busyText(nil))
    }

    @Test func mientrasEscuchaLaCompuertaEsDelCarro() async throws {
        let runner = MockRunner()
        runner.replies.mutate { $0 = [[.textDelta("Hecho.")]] }
        let rig = CarRig(runner: runner)
        rig.voice.holdOpen.mutate { $0 = true }
        rig.conversation.talk()
        await rig.waitFor { rig.conversation.phase == .listening }
        // Con el micrófono del carro abierto, ninguna otra superficie toma el turno.
        #expect(rig.gate.current == .carplay)
        #expect(rig.gate.begin(.phoneChat) == nil)
        #expect(rig.gate.begin(.glassesHUD) == nil)
        rig.voice.finish()
        await rig.settle()
        #expect(runner.received.value.count == 1)
        #expect(rig.gate.current == nil)
    }

    @Test func sinSesionDeAudioNoEscucha() async {
        let rig = CarRig(runner: MockRunner())
        rig.audio.fails.mutate { $0 = true }
        rig.conversation.talk()
        await rig.settle()
        #expect(rig.voice.captures.value == 0)
        #expect(rig.conversation.phase == .idle)
        #expect(!rig.conversation.audioActive)
    }

    @Test func listoTerminaLaEscuchaConLoOido() async {
        let runner = MockRunner()
        runner.replies.mutate { $0 = [[.textDelta("Hecho.")]] }
        let rig = CarRig(runner: runner, heard: ["apunta leche"])
        rig.voice.holdOpen.mutate { $0 = true }
        rig.conversation.talk()
        await rig.waitFor { rig.conversation.phase == .listening }
        rig.conversation.tapped(.done)
        await rig.settle()
        #expect(rig.voice.finishes.value == 1)
        #expect(runner.received.value.count == 1)
        #expect(rig.log.spoken == ["Hecho."])
    }

    @Test func unTapDeHablarMientrasConversaNoAbreOtra() async {
        let runner = SiriGatedRunner([.textDelta("Uno.")], gated: true)
        let rig = CarRig(runner: runner)
        rig.conversation.talk()
        await rig.waitFor { runner.started.value }
        rig.conversation.tapped(.talk)
        runner.open()
        await rig.settle()
        #expect(runner.received.value.count == 1)
        #expect(rig.voice.captures.value == 1)
    }

    // MARK: - Cancelación

    @Test func cancelarMientrasPiensaCierraElTurnoEnElChatYSueltaTodo() async {
        let runner = SiriGatedRunner([.textDelta("Nunca llega.")], gated: true)
        let rig = CarRig(runner: runner)
        rig.conversation.talk()
        await rig.waitFor { runner.started.value }
        await rig.waitFor { rig.conversation.phase == .thinking }
        rig.conversation.tapped(.cancel)
        await rig.settle()
        #expect(rig.phone.rendered.last == .turnFailed(text: CarPlayTurn.interruptedText, origin: .carplay))
        #expect(rig.log.spoken.isEmpty)
        #expect(rig.log.entries.value.last == "audio:off")
        #expect(rig.gate.current == nil)
        #expect(rig.conversation.phase == .idle)
    }

    @Test func cancelarEnLaColaQuitaLaPreguntaDelChat() async {
        let runner = QueuedRunner()
        let rig = CarRig(runner: runner)
        rig.conversation.talk()
        await rig.waitFor { rig.phone.rendered.count == 1 }
        rig.conversation.cancel()
        await rig.settle()
        #expect(rig.phone.rendered == [.userTurn(text: "¿qué tengo mañana?", origin: .carplay),
                                       .turnDropped(origin: .carplay)])
        #expect(rig.gate.current == nil)
    }

    @Test func cancelarMientrasEscuchaNoCorreTurno() async {
        let runner = MockRunner()
        let rig = CarRig(runner: runner)
        rig.voice.holdOpen.mutate { $0 = true }
        rig.conversation.talk()
        await rig.waitFor { rig.conversation.phase == .listening }
        rig.conversation.cancel()
        await rig.settle()
        #expect(rig.voice.cancels.value >= 1)
        #expect(runner.received.value.isEmpty)
        #expect(rig.log.entries.value == ["audio:on", "listen", "audio:off"])
    }

    @Test func desconectarElCarroCortaYSueltaElAudio() async {
        let runner = SiriGatedRunner([.textDelta("Nunca llega.")], gated: true)
        let rig = CarRig(runner: runner)
        rig.conversation.talk()
        await rig.waitFor { runner.started.value }
        rig.conversation.disconnect()
        #expect(!rig.conversation.audioActive)
        #expect(rig.conversation.phase == .idle)
        await rig.settle()
        #expect(rig.phone.rendered.last == .turnFailed(text: CarPlayTurn.interruptedText, origin: .carplay))
        #expect(rig.gate.current == nil)
    }

    @Test func callarDejaDeHablarYElRestoQuedaEnElChat() async {
        let runner = SiriGatedRunner([.textDelta("Primera oración. Segunda oración. "), .textDelta("Tercera.")],
                                     gated: true)
        let rig = CarRig(runner: runner)
        rig.speaker.gated.mutate { $0 = true }
        rig.conversation.talk()
        await rig.waitFor { runner.started.value }
        runner.open()
        await rig.waitFor { rig.log.spoken.count == 1 }
        rig.conversation.tapped(.stop)
        #expect(rig.conversation.phase == .idle)
        #expect(!rig.conversation.audioActive)
        await rig.settle()
        #expect(rig.log.spoken == ["Primera oración."])
        #expect(rig.phone.rendered.last == .assistantTurn(text: "Primera oración. Segunda oración. Tercera.",
                                                          origin: .carplay))
        #expect(rig.log.entries.value.filter { $0 == "audio:off" }.count == 1)
    }

    @Test func hablarTrasCallarEsperaAQueTermineElTurnoAnterior() async {
        let runner = SiriGatedRunner([.textDelta("Uno. Dos.")], gated: true)
        let rig = CarRig(runner: runner, heard: ["primero", nil])
        rig.speaker.gated.mutate { $0 = true }
        rig.conversation.talk()
        await rig.waitFor { runner.started.value }
        rig.conversation.hush()
        rig.conversation.talk()
        #expect(rig.conversation.phase == .thinking)
        rig.speaker.gated.mutate { $0 = false }
        runner.open()
        await rig.waitFor { rig.voice.captures.value == 2 }
        await rig.settle()
        #expect(rig.voice.captures.value == 2)
        #expect(rig.log.spoken == [CarPlayTurn.emptyText])
    }

    @Test func callarSinConversacionNoHaceNada() {
        let rig = CarRig(runner: MockRunner())
        rig.conversation.hush()
        #expect(rig.conversation.phase == .idle)
        #expect(rig.log.entries.value.isEmpty)
    }

    // MARK: - Honestidad (misma semántica que Siri y las gafas)

    @Test func errorDelTurnoSeDiceComoFallo() async {
        let runner = MockRunner()
        runner.replies.mutate { $0 = [[.textDelta("Voy a"), .error("Sin conexión con el modelo.")]] }
        let rig = CarRig(runner: runner)
        rig.conversation.talk()
        await rig.settle()
        #expect(rig.log.spoken == ["No pude responderte: Sin conexión con el modelo."])
        #expect(rig.phone.rendered.last == .turnFailed(text: "Sin conexión con el modelo.", origin: .carplay))
    }

    @Test func rechazoSeDiceYQuedaComoRechazo() async {
        let runner = MockRunner()
        runner.replies.mutate { $0 = [[.refused, .textDelta("Eso no lo hago.")]] }
        let rig = CarRig(runner: runner)
        rig.conversation.talk()
        await rig.settle()
        #expect(rig.log.spoken == ["Eso no lo hago."])
        #expect(rig.phone.rendered.last == .declined(text: "Eso no lo hago.", origin: .carplay))
    }

    @Test func loRetraidoNoSeSigueDiciendoYSeDiceLaCorreccion() async {
        let runner = MockRunner()
        runner.replies.mutate { $0 = [[.textDelta("Ya lo agendé. Te"), .retracted,
                                       .textDelta("No pude agendarlo todavía.")]] }
        let rig = CarRig(runner: runner)
        rig.conversation.talk()
        await rig.settle()
        // Lo retraído suena a lo sumo si ya había arrancado antes de la retracción
        // (una oración despachada pero aún no arrancada ya no suena: línea de voz);
        // la corrección se dice al final y nada de lo retraído después.
        let said = rig.log.spoken
        #expect(said.last == "No pude agendarlo todavía.")
        #expect(said == ["No pude agendarlo todavía."] || said == ["Ya lo agendé.", "No pude agendarlo todavía."])
        #expect(rig.phone.rendered.last == .assistantTurn(text: "No pude agendarlo todavía.", origin: .carplay))
    }

    @Test func avisoDeFalloDeToolSinTextoSeDice() async {
        let runner = MockRunner()
        runner.replies.mutate { $0 = [[.toolFailure("No pude crear el evento.")]] }
        let rig = CarRig(runner: runner)
        rig.conversation.talk()
        await rig.settle()
        #expect(rig.log.spoken == ["No pude crear el evento."])
    }

    // MARK: - Confirmaciones

    @Test func confirmacionPorVozSePreguntaYSigue() async {
        let rig = CarRig(runner: MockRunner(), heard: ["agéndame el dentista", "sí, dale"])
        let runner = CarApprovalRunner(router: rig.confirmRouter())
        rig.readiness = .ready(runner: runner, sessionId: "s1")
        rig.conversation.talk()
        await rig.settle()
        #expect(runner.decisions.value == [true])
        #expect(rig.log.spoken == ["Claro, lo agendo.",
                                   CarPlayTurn.confirmationPrompt("Crear evento 'Dentista' el jueves 15:00"),
                                   "Listo, quedó en tu agenda."])
        #expect(rig.phases.contains(.confirming))
        #expect(rig.voice.captures.value == 2)
        #expect(rig.pending.isEmpty)
    }

    @Test func confirmacionConElBotonNoNiegaYCortaLaEscucha() async {
        let rig = CarRig(runner: MockRunner(), heard: ["agéndame el dentista"])
        let runner = CarApprovalRunner(router: rig.confirmRouter())
        rig.readiness = .ready(runner: runner, sessionId: "s1")
        rig.voice.holdFrom.mutate { $0 = 2 }
        rig.conversation.talk()
        await rig.waitFor { rig.conversation.phase == .confirming && rig.voice.captures.value == 2 }
        #expect(rig.conversation.phase == .confirming)
        rig.conversation.tapped(.no)
        await rig.settle()
        #expect(runner.decisions.value == [false])
        #expect(rig.log.spoken.last == "No lo agendé.")
    }

    @Test func confirmacionConElBotonSiAprueba() async {
        let rig = CarRig(runner: MockRunner(), heard: ["agéndame el dentista"])
        let runner = CarApprovalRunner(router: rig.confirmRouter())
        rig.readiness = .ready(runner: runner, sessionId: "s1")
        rig.voice.holdFrom.mutate { $0 = 2 }
        rig.conversation.talk()
        await rig.waitFor { rig.conversation.phase == .confirming && rig.voice.captures.value == 2 }
        rig.conversation.tapped(.yes)
        await rig.settle()
        #expect(runner.decisions.value == [true])
        #expect(rig.voice.cancels.value >= 1)
    }

    @Test func sinRespuestaVenceYNiega() async {
        let rig = CarRig(runner: MockRunner(), heard: ["agéndame el dentista"], confirmTimeout: .milliseconds(40))
        let runner = CarApprovalRunner(router: rig.confirmRouter())
        rig.readiness = .ready(runner: runner, sessionId: "s1")
        // La segunda captura (la respuesta) queda abierta hasta que vence.
        rig.voice.holdFrom.mutate { $0 = 2 }
        rig.conversation.talk()
        await rig.settle()
        #expect(rig.phases.contains(.confirming))
        #expect(runner.decisions.value == [false])
    }

    @Test func respuestaQueNoSeEntiendeNiega() async {
        let rig = CarRig(runner: MockRunner(), heard: ["agéndame el dentista", "eh, a ver"])
        let runner = CarApprovalRunner(router: rig.confirmRouter())
        rig.readiness = .ready(runner: runner, sessionId: "s1")
        rig.conversation.talk()
        await rig.settle()
        #expect(runner.decisions.value == [false])
        #expect(rig.log.spoken.contains(CarPlayTurn.unclearText))
    }

    @Test func cancelarDuranteLaConfirmacionNiegaYCorta() async {
        let rig = CarRig(runner: MockRunner(), heard: ["agéndame el dentista"])
        let runner = CarApprovalRunner(router: rig.confirmRouter())
        rig.readiness = .ready(runner: runner, sessionId: "s1")
        rig.voice.holdFrom.mutate { $0 = 2 }
        rig.conversation.talk()
        await rig.waitFor { rig.conversation.phase == .confirming && rig.voice.captures.value == 2 }
        rig.conversation.cancel()
        await rig.settle()
        #expect(runner.decisions.value.allSatisfy { !$0 })
        #expect(rig.phone.rendered.last == .turnFailed(text: CarPlayTurn.interruptedText, origin: .carplay))
        #expect(rig.gate.current == nil)
    }

    @Test func callarAntesDeConfirmarNiega() async {
        let rig = CarRig(runner: MockRunner(), heard: ["agéndame el dentista"])
        let runner = CarApprovalRunner(router: rig.confirmRouter())
        rig.readiness = .ready(runner: runner, sessionId: "s1")
        rig.speaker.gated.mutate { $0 = true }
        rig.conversation.talk()
        await rig.waitFor { rig.log.spoken.count == 1 }
        rig.conversation.hush()
        await rig.settle()
        #expect(runner.decisions.value == [false])
        #expect(rig.log.spoken == ["Claro, lo agendo."])
    }

    @Test func accionDeRiesgoSeNiegaSinPreguntarYQuedaPendiente() async {
        let rig = CarRig(runner: MockRunner(), heard: ["borra la reunión"])
        let runner = CarApprovalRunner(router: rig.confirmRouter(), operation: "delete",
                                       summary: "Borrar el evento ABC")
        rig.readiness = .ready(runner: runner, sessionId: "s1")
        // El Sensorimotor real la niega por política y avisa al buzón (ver CarPlayPolicyTests);
        // aquí el router también la niega sin preguntar y el runner lo dice.
        await rig.approvals.refused(ConfirmationRequest(tool: "calendar", operation: "delete",
                                                        summary: "Borrar el evento ABC", input: .null,
                                                        surface: .carplay))
        rig.conversation.talk()
        await rig.settle()
        #expect(runner.decisions.value == [false])
        #expect(!rig.phases.contains(.confirming))
        #expect(rig.voice.captures.value == 1)
        #expect(rig.pending == [["Borrar el evento ABC"]])
    }

    @Test func buzonCerradoNiega() async {
        let approvals = CarPlayApprovals()
        let ask = ConfirmationRequest(tool: "calendar", operation: "create", summary: "x", input: .null,
                                      surface: .carplay)
        #expect(await approvals.confirm(ask) == false)          // sin quien pregunte
        approvals.setAsk { _ in true }
        #expect(await approvals.confirm(ask) == false)          // cerrado
        approvals.open()
        #expect(await approvals.confirm(ask))
        var other = ask
        other.surface = .phoneChat
        #expect(await approvals.confirm(other) == false)        // jamás las de otra superficie
        approvals.close()
        #expect(!approvals.isOpen)
        #expect(await approvals.confirm(ask) == false)
    }

    @Test func buzonCerradoMientrasPreguntaNiegaAunqueDigaQueSi() async {
        let approvals = CarPlayApprovals()
        approvals.open()
        approvals.setAsk { _ in
            approvals.close()
            return true
        }
        #expect(await approvals.confirm(ConfirmationRequest(tool: "calendar", operation: "create", summary: "x",
                                                            input: .null, surface: .carplay)) == false)
    }
}

// MARK: - Política, persistencia y template

private struct FakeTool: SensorimotorTool {
    let name: String
    let ran: Locked<Int>
    var spec: ToolSpec { .client(name: name, description: "x", inputSchema: .object(["type": .string("object")])) }
    func kind(for input: JSONValue) -> ToolKind { .efferent }
    func confirmationSummary(for input: JSONValue) -> String { "\(name) \(operation(for: input))" }
    func execute(_ input: JSONValue) async -> ToolResult {
        ran.mutate { $0 += 1 }
        return ToolResult(content: "hecho")
    }
}

@Suite("CarPlay — política, superficie y template")
struct CarPlayPolicyTests {
    private func sensorimotor(_ approvals: CarPlayApprovals, ran: Locked<Int>) -> Sensorimotor {
        let router = SurfaceConfirmationRouter(phone: FailClosedConfirmation(), glasses: { _ in true },
                                               carplay: approvals)
        return Sensorimotor(tools: [FakeTool(name: "calendar", ran: ran), FakeTool(name: GlassesCameraTool.name, ran: ran),
                                    FakeTool(name: "camera", ran: ran)],
                            policy: .app(ownerAllowlist: { [] }), confirmation: router)
    }

    @Test func desdeElCarroLoDeRiesgoSeNiegaYQuedaPendiente() async {
        let ran = Locked(0)
        let approvals = CarPlayApprovals()
        approvals.open()
        let asked = Locked(0)
        approvals.setAsk { _ in asked.mutate { $0 += 1 }; return true }
        let motor = sensorimotor(approvals, ran: ran)
        let delete = await motor.execute(name: "calendar", input: .object(["action": .string("delete")]),
                                         surface: .carplay)
        #expect(delete.isError)
        #expect(delete.isRejection)
        #expect(delete.content == CarPlayTurn.pendingRefusal("calendar delete"))
        #expect(delete.content.contains("pendiente en el teléfono"))
        let phoneCamera = await motor.execute(name: "camera", input: .object([:]), surface: .carplay)
        #expect(phoneCamera.isRejection)
        #expect(approvals.takePending() == ["calendar delete", "camera default"])
        #expect(approvals.takePending().isEmpty)
        #expect(ran.value == 0)
        #expect(asked.value == 0)
    }

    @Test func camaraDeLasGafasDesdeElCarroSeNiegaSinPendiente() async {
        let ran = Locked(0)
        let approvals = CarPlayApprovals()
        approvals.open()
        approvals.setAsk { _ in true }
        let motor = sensorimotor(approvals, ran: ran)
        let result = await motor.execute(name: GlassesCameraTool.name, input: .object([:]), surface: .carplay)
        #expect(result.content == CarPlayTurn.cameraRefusal)
        #expect(ran.value == 0)
        #expect(approvals.takePending().isEmpty)
        #expect(await SurfaceConfirmationRouter(phone: FailClosedConfirmation(), glasses: { _ in true },
                                                carplay: approvals)
            .confirm(ConfirmationRequest(tool: GlassesCameraTool.name, operation: "x", summary: "s", input: .null,
                                         surface: .carplay)) == false)
    }

    @Test func loDeBajoRiesgoSePreguntaEnElCarro() async {
        let ran = Locked(0)
        let approvals = CarPlayApprovals()
        approvals.open()
        let asked = Locked<[String]>([])
        approvals.setAsk { request in asked.mutate { $0.append(request.summary) }; return true }
        let motor = sensorimotor(approvals, ran: ran)
        let create = await motor.execute(name: "calendar", input: .object(["action": .string("create")]),
                                         surface: .carplay)
        #expect(create.content == "hecho")
        #expect(asked.value == ["calendar create"])
        #expect(ran.value == 1)
        // Sin buzón de CarPlay cableado: fail-closed.
        #expect(await SurfaceConfirmationRouter(phone: AskingPhone(asked: Locked([])), glasses: nil)
            .confirm(ConfirmationRequest(tool: "calendar", operation: "create", summary: "z", input: .null,
                                         surface: .carplay)) == false)
    }

    @Test func lasDeOtrasSuperficiesNoPasanPorElCarro() async {
        let approvals = CarPlayApprovals()
        approvals.open()
        let asked = Locked(0)
        approvals.setAsk { _ in asked.mutate { $0 += 1 }; return true }
        let phone = Locked<[String]>([])
        let router = SurfaceConfirmationRouter(phone: AskingPhone(asked: phone), glasses: nil, carplay: approvals)
        #expect(await router.confirm(ConfirmationRequest(tool: "calendar", operation: "delete", summary: "chat",
                                                         input: .null, surface: .phoneChat)))
        #expect(phone.value == ["chat"])
        #expect(asked.value == 0)
        // Lo negado por política de otra superficie no queda pendiente en CarPlay.
        await router.refused(ConfirmationRequest(tool: GlassesCameraTool.name, operation: "x", summary: "s",
                                                 input: .null, surface: .siri))
        await router.refused(ConfirmationRequest(tool: "calendar", operation: "delete", summary: "chat",
                                                 input: .null, surface: .phoneChat))
        #expect(approvals.takePending().isEmpty)
    }

    @Test func voiceConfirmableCubreLoReversible() {
        func request(_ tool: String, _ op: String) -> ConfirmationRequest {
            ConfirmationRequest(tool: tool, operation: op, summary: "s", input: .null, surface: .carplay)
        }
        #expect(CarPlayTurn.refusal(for: request("calendar", "create")) == nil)
        #expect(CarPlayTurn.refusal(for: request("reminders", "complete")) == nil)
        #expect(CarPlayTurn.refusal(for: request("anima_reminders", "create")) == nil)
        #expect(CarPlayTurn.refusal(for: request("goals", "declare")) == nil)
        #expect(CarPlayTurn.refusal(for: request("calendar", "delete")) != nil)
        #expect(CarPlayTurn.refusal(for: request("audio", "record")) != nil)
        #expect(CarPlayTurn.refusal(for: request("desconocida", "x")) != nil)
        var chat = request("calendar", "delete")
        chat.surface = .phoneChat
        #expect(CarPlayTurn.refusal(for: chat) == nil)
        #expect(SurfaceConfirmationRouter.refusal(for: chat) == nil)
        #expect(!CarPlayTurn.leavesPending(request(GlassesCameraTool.name, "capture_pov")))
        #expect(CarPlayTurn.leavesPending(request("calendar", "delete")))
    }

    @Test(arguments: [
        // Un sí limpio aprueba.
        ("sí", CarPlayTurn.Answer.approve), ("Sí, dale", .approve), ("hazlo por favor", .approve), ("ok", .approve),
        ("de una", .approve), ("claro que sí", .approve), ("SI", .approve), ("confirmo", .approve),
        // La negación gana.
        ("no", .deny), ("No, mejor no", .deny), ("sí... no, cancela", .deny), ("mejor no", .deny), ("déjalo", .deny),
        // Un sí con condición NO aprueba la acción original (control negativo del bug: antes eran true).
        ("sí pero a las cinco", .amend), ("dale, pero cámbialo al viernes", .amend), ("sí, mejor el lunes", .amend),
        ("ok a las 4", .amend), ("el jueves", .amend), ("sí, en vez de eso ponlo mañana", .amend),
        // Afirmativos ambiguos: en la duda, no.
        ("va", .unclear), ("bueno, a ver", .unclear), ("bueno", .unclear), ("listo", .unclear), ("porfa", .unclear),
        ("sí, creo", .unclear), ("", .unclear), ("eh", .unclear), ("mmm", .unclear),
    ] as [(String, CarPlayTurn.Answer)])
    func respuestaHablada(_ said: String, _ expected: CarPlayTurn.Answer) {
        #expect(CarPlayTurn.answer(said) == expected)
        #expect(CarPlayTurn.answer(said).approves == (expected == .approve))
    }

    @Test func laPreguntaDiceLaAccionSinEmojis() {
        let prompt = CarPlayTurn.confirmationPrompt("Crear evento '🎂 Cumple' el viernes")
        #expect(prompt.hasPrefix("Para eso necesito tu ok: Crear evento '"))
        #expect(prompt.hasSuffix("¿Lo hago? Di sí o no."))
        #expect(!prompt.contains("🎂"))
        #expect(CarPlayTurn.utterance("**Hola** 👋") == "Hola")
    }

    @Test func superficieCarPlayEsSoloVozConBotonesSimples() {
        #expect(SurfaceID(rawValue: "carplay") == .carplay)
        #expect(SurfaceCapabilities.carplay.maxButtons == 2)
        #expect(SurfaceCapabilities.carplay.voiceIn)
        #expect(SurfaceCapabilities.carplay.audioOut)
        #expect(!SurfaceCapabilities.carplay.freeText)
        #expect(!SurfaceCapabilities.carplay.images)
        #expect(AgentLoop.surfaceHint(.carplay) == AgentLoop.carplaySurfaceHint)
        #expect(AgentLoop.carplaySurfaceHint.contains("conduce: respuestas cortas, solo voz, nada visual"))
        #expect(CarPlayAudioSpec.conversation == CarPlayAudioSpec(category: .playAndRecord, mode: .default,
                                                                  mixesWithOthers: false,
                                                                  notifiesOthersOnRelease: true))
        #expect(throws: Never.self) { try SilentCarPlayAudio().activateConversation() }
        SilentCarPlayAudio().releaseConversation()
    }

    @Test func elTemplateRespetaLosLimitesDeApple() {
        let states = CarPlayTemplateModel.states(name: "Nova")
        #expect(states.count == 5)                                   // ≤5 estados
        #expect(states.allSatisfy { $0.buttons.count <= CarPlayTurn.maxButtons })
        #expect(Set(states.map(\.identifier)).count == 5)
        #expect(states.first?.identifier == CarPlayTemplateModel.identifier(.idle))   // el de reposo, primero
        #expect(states.first?.titleVariants == ["Hablar con Nova", "Hablar"])
        #expect(states.first?.buttons == [.talk])
        #expect(CarPlayTemplateModel.state(.listening, name: "Nova").buttons == [.done, .cancel])
        #expect(CarPlayTemplateModel.state(.thinking, name: "Nova").buttons == [.cancel])
        #expect(CarPlayTemplateModel.state(.speaking, name: "Nova").buttons == [.stop])
        #expect(CarPlayTemplateModel.state(.confirming, name: "Nova").buttons == [.yes, .no])
        // Nada de texto largo: títulos cortos, el nombre recortado.
        #expect(states.flatMap(\.titleVariants).allSatisfy { $0.count <= 32 })
        #expect(CarPlayTemplateModel.displayName("  ") == "Anima")
        #expect(CarPlayTemplateModel.displayName(String(repeating: "x", count: 40)).count <= 18)
        #expect(CarPlayButton.allCases.allSatisfy { !$0.title.isEmpty && $0.title.count <= 8 })
        #expect(Set(CarPlayButton.allCases.map(\.symbol)).count == CarPlayButton.allCases.count)
    }

    @MainActor
    @Test func turnoDeCarPlayPersisteConSuMarcaPistaYChip() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let provider = CapturingProvider([.text("Tienes el dentista a las 3."), .text("Por el teléfono.")])
        let loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [], serverTools: [], sleep: { _ in })
        let sid = try store.startSession()
        let rig = CarRig(runner: loop, heard: ["¿qué tengo hoy?"], ready: .ready(runner: loop, sessionId: sid))
        rig.conversation.talk()
        await rig.settle()
        #expect(rig.log.spoken == ["Tienes el dentista a las 3."])
        for await _ in await loop.run(sessionId: sid, userText: "hola") {}
        #expect(try store.surfaces(sessionId: sid) == [.carplay, .carplay, .phoneChat, .phoneChat])
        let hints = provider.captures.value.map { capture in
            capture.messages.contains { $0.role == .system && $0.content == [.text(AgentLoop.carplaySurfaceHint)] }
        }
        #expect(hints == [true, false])
        let history = ChatViewModel.history(turns: try store.historyPage().turns, boundaries: [:])
        let owner = history.filter { $0.role == .user }
        #expect(owner.first?.channelChip?.label == "CarPlay")
        #expect(owner.first?.channelChip?.id == "chat.userMessage.carplay")
        #expect(owner.last?.channelChip == nil)
    }

    @MainActor
    @Test func elChatEspejaElTurnoDeCarPlayConSuChip() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let chat = ChatViewModel(loop: try FullHistoryStoreTests.loop(store, queue), sessionId: try store.startSession())
        await chat.render(.userTurn(text: "¿qué tengo?", origin: .carplay))
        #expect(chat.isStreaming)
        #expect(chat.messages.first?.channelChip?.label == "CarPlay")
        await chat.render(.assistantTurn(text: "Nada hoy.", origin: .carplay))
        #expect(chat.messages.last?.text == "Nada hoy.")
    }

    @Test func compuertaGenericaReintentaSoloConSuPropiaSuperficie() async throws {
        let gate = TurnGate()
        let first = try #require(gate.begin(.carplay))
        // Fuera del pool cooperativo: con la suite entera en paralelo no se atrasa.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { gate.end(first) }
        let retried = await gate.acquire(.carplay, retrying: .seconds(10))
        #expect(retried != nil)
        if let retried { gate.end(retried) }
        let chat = try #require(gate.begin(.phoneChat))
        #expect(await gate.acquire(.carplay, retrying: .seconds(2)) == nil)
        gate.end(chat)
    }

    @Test func spokenScriptConRemisionPropia() {
        var script = SpokenScript(limit: 20, tail: CarPlayTurn.chatTail)
        _ = script.feed("Una oración corta. Otra oración que ya no cabe. ")
        #expect(script.finish().last == CarPlayTurn.chatTail)
        #expect(SpokenScript().tail == HUDSummary.phoneTail)
    }
}
