import Foundation
import Testing
@testable import AnimaKit

// Seguimiento de la review de #41 (CarPlay). Cada hallazgo con su test y, donde
// aplica, un CONTROL NEGATIVO: el mismo escenario con el comportamiento viejo
// reproduce el bug (así el test de verdad lo detectaría).

// MARK: - Dobles

/// Doble de AVAudioSession: registra cada llamada y el estado REAL de la sesión.
final class FakeAudioControl: AudioSessionControl, @unchecked Sendable {
    let ops = Locked<[String]>([])
    let active = Locked(false)
    func configure(_ spec: CarPlayAudioSpec) throws { ops.mutate { $0.append("category") } }
    func setActive(_ value: Bool, notifyOthers: Bool) throws {
        active.mutate { $0 = value }
        ops.mutate { $0.append(value ? "on" : (notifyOthers ? "off+notify" : "off")) }
    }
}

/// El adaptador de #41 (el bug): captura y TTS re-activaban la sesión siempre.
final class LegacyCarPlayAudio: CarPlayAudioPort, AudioSessionPort, @unchecked Sendable {
    let control: FakeAudioControl
    init(_ control: FakeAudioControl) { self.control = control }
    func activateConversation() throws { try control.setActive(true, notifyOthers: false) }
    func releaseConversation() { try? control.setActive(false, notifyOthers: true) }
    func hfpInputAvailable() -> Bool { false }
    func activateHFP() throws { try activateConversation() }
    func currentInputIsHFP() -> Bool { false }
    func activatePhoneMic() throws { try activateConversation() }
    func activatePlaybackA2DP() throws { try activateConversation() }
    func deactivate() {}
}

/// Reconocedor que no oye nada (la captura dura hasta cancelar o "Listo").
final class SilentRecognizer: SpeechRecognitionPort, @unchecked Sendable {
    func start(onPartial: @escaping @Sendable (String) -> Void) throws {}
    func stop() {}
}

/// La captura REAL de las gafas (VoiceCaptureLoop: asentar ruta → reconocer →
/// teardown → releaseCapture) sobre el puerto de audio que se le pase.
final class LoopVoice: VoiceCapturePort, @unchecked Sendable {
    let loop: VoiceCaptureLoop
    let running = Locked(false)
    init(audio: any AudioSessionPort) {
        loop = VoiceCaptureLoop(audio: audio, detector: TurnEndDetector(silence: 30, maxDuration: 30),
                                settle: 0, poll: 0.005)
    }
    func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void) async -> String? {
        running.mutate { $0 = true }
        defer { running.mutate { $0 = false } }
        return await loop.run(recognizer: { SilentRecognizer() }, onRoute: onRoute)
    }
    func cancel() { loop.cancel() }
    func finish() { loop.finish() }
}

@MainActor
private func makeConversation(audio: any CarPlayAudioPort, voice: any VoiceCapturePort,
                              answerVoice: (any VoiceCapturePort)? = nil, runner: any TurnRunner = MockRunner(),
                              gate: TurnGate = TurnGate(), approvals: CarPlayApprovals = CarPlayApprovals())
    -> CarPlayConversation {
    let log = CarLog()
    return CarPlayConversation(readiness: { .ready(runner: runner, sessionId: "s1") }, gate: gate,
                               gateRetry: .milliseconds(30), voice: voice, answerVoice: answerVoice,
                               speech: CarSpeaker(log: log), audio: audio, approvals: approvals)
}

@MainActor
private func wait(_ timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
}

// MARK: - MEDIO 1: la sesión de audio no queda activa al desconectar

@MainActor
@Suite("CarPlay #41 review — MEDIO 1: sesión de audio al desconectar")
struct CarPlayAudioReleaseTests {
    @Test func desconectarMientrasEscuchaDejaLaSesionInactiva() async {
        let control = FakeAudioControl()
        let owner = CarPlayAudioSessionOwner(control: control)
        let voice = LoopVoice(audio: owner)
        let conversation = makeConversation(audio: owner, voice: voice)
        conversation.talk()
        // La captura ya asentó su ruta (re-afirmó la sesión) y está escuchando.
        await wait { conversation.phase == .listening && voice.running.value
            && control.ops.value.filter { $0 == "on" }.count >= 2 }
        try? await Task.sleep(for: .milliseconds(20))
        conversation.disconnect()
        await conversation.waitUntilIdle()
        await wait { !voice.running.value }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(control.active.value == false)
        #expect(!owner.isOwned)
        // La captura rezagada ya no re-activa: nada de "on" después del "off".
        let ops = control.ops.value
        let off = ops.lastIndex(of: "off+notify")
        #expect(off != nil)
        #expect(!ops[(off ?? 0)...].contains("on"))
    }

    // CONTROL NEGATIVO: el adaptador viejo, misma secuencia → on, on, off, on ⇒ queda activa.
    @Test func controlNegativoElAdaptadorViejoLaDejabaActiva() async {
        let control = FakeAudioControl()
        let legacy = LegacyCarPlayAudio(control)
        let voice = LoopVoice(audio: legacy)
        let conversation = makeConversation(audio: legacy, voice: voice)
        conversation.talk()
        // La captura ya asentó su ruta (re-afirmó la sesión) y está escuchando.
        await wait { conversation.phase == .listening && voice.running.value
            && control.ops.value.filter { $0 == "on" }.count >= 2 }
        try? await Task.sleep(for: .milliseconds(20))
        conversation.disconnect()
        await conversation.waitUntilIdle()
        await wait { !voice.running.value }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(control.active.value == true)
        #expect(control.ops.value.suffix(2) == ["off+notify", "on"])
    }

    @Test func desconectarEsperandoElSiNoDejaLaSesionInactiva() async {
        let control = FakeAudioControl()
        let owner = CarPlayAudioSessionOwner(control: control)
        let log = CarLog()
        let request = CarVoice(["agéndame el dentista"], log: log)
        let answer = LoopVoice(audio: owner)
        let approvals = CarPlayApprovals()
        let router = SurfaceConfirmationRouter(phone: FailClosedConfirmation(), glasses: nil, carplay: approvals)
        let runner = CarApprovalRunner(router: router)
        let conversation = makeConversation(audio: owner, voice: request, answerVoice: answer, runner: runner,
                                            approvals: approvals)
        conversation.talk()
        await wait { conversation.phase == .confirming && answer.running.value }
        conversation.disconnect()
        await conversation.waitUntilIdle()
        await wait { !answer.running.value }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(runner.decisions.value == [false])
        #expect(control.active.value == false)
    }

    @Test func elDuenoSoloReactivaMientrasLaTiene() throws {
        let control = FakeAudioControl()
        let owner = CarPlayAudioSessionOwner(control: control)
        try owner.activatePlaybackA2DP()          // sin dueño: no toca la sesión
        try owner.activatePhoneMic()
        try owner.activateHFP()
        #expect(control.ops.value.isEmpty)
        try owner.activateConversation()
        try owner.activatePlaybackA2DP()          // con dueño: re-afirma
        owner.deactivate()                        // la captura no la suelta entre fases
        #expect(control.active.value)
        owner.releaseConversation()
        owner.releaseConversation()               // idempotente
        #expect(control.ops.value == ["category", "on", "on", "off+notify"])
        #expect(!owner.hfpInputAvailable())
        #expect(!owner.currentInputIsHFP())
        #expect(owner.spec == .conversation)
    }
}

// MARK: - MEDIO 2: base y voz con la escena en background

@MainActor
@Suite("CarPlay #41 review — MEDIO 2: background y base")
struct CarPlayLifecycleTests {
    final class Holds {
        var count = 0
        var work = 0
        var workEnded = 0
    }

    private func lifecycle(_ rig: CarRig, _ holds: Holds) -> CarPlaySceneLifecycle {
        CarPlaySceneLifecycle(conversation: rig.conversation, hold: { holds.count += $0 ? 1 : -1 },
                              backgroundWork: {
                                  holds.work += 1
                                  return { holds.workEnded += 1 }
                              })
    }

    @Test func enBackgroundPensandoCortaLimpioYSueltaLaBase() async {
        let runner = SiriGatedRunner([.textDelta("Nunca llega.")], gated: true)
        let rig = CarRig(runner: runner)
        let holds = Holds()
        let scene = lifecycle(rig, holds)
        scene.didConnect()
        scene.didBecomeActive()
        #expect(holds.count == 1)
        rig.conversation.talk()
        await rig.waitFor { runner.started.value }
        scene.didEnterBackground()
        #expect(holds.count == 0)                 // el hold de la escena se suelta YA
        #expect(holds.work == 1)                  // …y un background task cubre el cierre
        await rig.settle()
        await rig.waitFor { holds.workEnded == 1 }
        #expect(holds.workEnded == 1)
        #expect(rig.phone.rendered.last == .turnFailed(text: CarPlayTurn.interruptedText, origin: .carplay))
        #expect(!rig.conversation.audioActive)
        #expect(rig.gate.current == nil)
        scene.didBecomeActive()                   // al volver se retoma
        #expect(holds.count == 1)
        scene.didDisconnect()
        #expect(holds.count == 0)
    }

    // Control: en reposo no hace falta background task; el hold igual se suelta.
    @Test func enBackgroundEnReposoSoloSueltaLaBase() {
        let rig = CarRig(runner: MockRunner())
        let holds = Holds()
        let scene = lifecycle(rig, holds)
        scene.didConnect()
        scene.didEnterBackground()
        #expect(holds.count == 0)
        #expect(holds.work == 0)
        #expect(!scene.holdsDatabase)
    }

    @Test func desconectarHablandoSueltaTodo() async {
        let runner = SiriGatedRunner([.textDelta("Primera. Segunda.")], gated: false)
        let rig = CarRig(runner: runner)
        rig.speaker.gated.mutate { $0 = true }
        let holds = Holds()
        let scene = lifecycle(rig, holds)
        scene.didConnect()
        rig.conversation.talk()
        await rig.waitFor { rig.conversation.phase == .speaking }
        scene.didDisconnect()
        await rig.settle()
        await rig.waitFor { holds.workEnded == 1 }
        #expect(holds.count == 0)
        #expect(holds.workEnded == holds.work)
        #expect(rig.log.entries.value.last == "audio:off")
    }

    // Menor: CarPlay restaura Anima al arrancar el carro ⇒ NO abre el micrófono.
    @Test func laPrimeraActivacionNoAbreElMicrofono() async {
        let rig = CarRig(runner: MockRunner())
        let holds = Holds()
        let scene = lifecycle(rig, holds)
        scene.didConnect()
        scene.didBecomeActive()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.voice.captures.value == 0)
        #expect(rig.log.entries.value.isEmpty)     // ni la sesión de audio se tocó
        #expect(!rig.conversation.isBusy)
    }

    // …pero si el conductor vuelve a abrir Anima en el carro, escucha de una.
    @Test func reabrirAnimaEnElCarroEscucha() async {
        let runner = MockRunner()
        runner.replies.mutate { $0 = [[.textDelta("Hola.")]] }
        let rig = CarRig(runner: runner)
        let holds = Holds()
        let scene = lifecycle(rig, holds)
        scene.didConnect()
        scene.didBecomeActive()
        scene.didEnterBackground()
        scene.didBecomeActive()
        await rig.settle()
        #expect(rig.voice.captures.value == 1)
        // Desconectado no reacciona.
        scene.didDisconnect()
        scene.didBecomeActive()
        #expect(holds.count == 0)
    }
}

// MARK: - MEDIO 3: ritmo de los estados del template

/// Template que IGNORA cambios que llegan antes de `window` desde el último aceptado.
@MainActor
final class RateLimitedTemplate {
    let window: Duration
    private(set) var active: String?
    private var lastAccepted: ContinuousClock.Instant?
    private(set) var ignored = 0
    init(window: Duration) { self.window = window }
    func activate(_ id: String) {
        let now = ContinuousClock.now
        if let lastAccepted, now - lastAccepted < window {
            ignored += 1
            return
        }
        lastAccepted = now
        active = id
    }
}

@MainActor
@Suite("CarPlay #41 review — MEDIO 3: estados del template")
struct CarPlayPresenterTests {
    @Test func cambiosRapidosTerminanEnLaFaseFinal() async {
        let template = RateLimitedTemplate(window: .milliseconds(120))
        let presenter = CarPlayStatePresenter(minInterval: .milliseconds(40), reconcileAfter: .milliseconds(60),
                                              apply: { template.activate($0) }, current: { template.active })
        for phase in [CarPlayPhase.listening, .thinking, .speaking, .thinking, .speaking, .idle] {
            presenter.show(phase)
        }
        await wait { template.active == CarPlayTemplateModel.identifier(.idle) }
        #expect(template.active == CarPlayTemplateModel.identifier(.idle))
        #expect(presenter.target == CarPlayTemplateModel.identifier(.idle))
        presenter.stop()
    }

    // CONTROL NEGATIVO: aplicar cada cambio directo (como #41) deja el template en "Responde…".
    @Test func controlNegativoSinPresenterQuedaEnRespondiendo() async {
        let template = RateLimitedTemplate(window: .milliseconds(120))
        template.activate(CarPlayTemplateModel.identifier(.speaking))
        template.activate(CarPlayTemplateModel.identifier(.idle))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(template.active == CarPlayTemplateModel.identifier(.speaking))
        #expect(template.ignored == 1)
    }

    @Test func espaciaLosCambiosYNoReaplicaSiYaQuedo() async {
        final class Box { var applied: [String] = []; var current: String? }
        let box = Box()
        let presenter = CarPlayStatePresenter(minInterval: .milliseconds(30), reconcileAfter: .milliseconds(20),
                                              apply: { box.applied.append($0); box.current = $0 },
                                              current: { box.current })
        presenter.show(.listening)
        presenter.show(.thinking)
        presenter.show(.speaking)               // colapsa: solo la última de las que esperaban
        await wait { box.applied.count >= 2 }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(box.applied == [CarPlayTemplateModel.identifier(.listening),
                                CarPlayTemplateModel.identifier(.speaking)])
        presenter.stop()
    }

    @Test func laRespuestaQuedaRespondiendoSinAlternarPorOracion() async {
        let runner = MockRunner()
        runner.replies.mutate { $0 = [[.textDelta("Uno. "), .textDelta("Dos. "), .textDelta("Tres.")]] }
        let rig = CarRig(runner: runner)
        rig.conversation.talk()
        await rig.settle()
        #expect(rig.log.spoken == ["Uno.", "Dos.", "Tres."])
        #expect(rig.phases == [.listening, .thinking, .speaking, .idle])
    }
}

// MARK: - Menores

@MainActor
@Suite("CarPlay #41 review — menores")
struct CarPlayMinorTests {
    // Ventana de 20 s real: una escucha vacía se repite; el sí llega en la tercera.
    @Test func laConfirmacionReEscuchaSiNoOyoNada() async {
        let rig = CarRig(runner: MockRunner(), heard: ["agéndame el dentista", nil, nil, "sí"])
        let runner = CarApprovalRunner(router: rig.confirmRouter())
        rig.readiness = .ready(runner: runner, sessionId: "s1")
        rig.conversation.talk()
        await rig.settle()
        #expect(runner.decisions.value == [true])
        #expect(rig.voice.captures.value == 4)
    }

    // Los botones siguen valiendo después de escuchas vacías (antes: no a los ~8 s).
    @Test func losBotonesValenHastaElTope() async {
        let rig = CarRig(runner: MockRunner(), heard: ["agéndame el dentista"], confirmTimeout: .seconds(10))
        let runner = CarApprovalRunner(router: rig.confirmRouter())
        rig.readiness = .ready(runner: runner, sessionId: "s1")
        rig.conversation.talk()
        await rig.waitFor { rig.conversation.phase == .confirming && rig.voice.captures.value >= 4 }
        #expect(rig.conversation.phase == .confirming)
        rig.conversation.tapped(.yes)
        await rig.settle()
        #expect(runner.decisions.value == [true])
    }

    @Test func sinMicrofonoNoInsistePeroElBotonVale() async {
        let rig = CarRig(runner: MockRunner(), heard: ["agéndame el dentista"], confirmTimeout: .seconds(10))
        let runner = CarApprovalRunner(router: rig.confirmRouter())
        rig.readiness = .ready(runner: runner, sessionId: "s1")
        rig.conversation.talk()
        await rig.waitFor { rig.conversation.phase == .confirming && rig.voice.captures.value == 2 }
        rig.voice.failure.mutate { $0 = .microphoneUnavailable(route: nil, detail: "x") }
        await rig.waitFor { rig.voice.captures.value == 3 }
        try? await Task.sleep(for: .milliseconds(600))
        #expect(rig.voice.captures.value == 3)      // no gira en vacío
        rig.conversation.tapped(.no)
        await rig.settle()
        #expect(runner.decisions.value == [false])
    }

    @Test func unSiConCondicionNoApruebaYPideLaCorreccion() async {
        let rig = CarRig(runner: MockRunner(), heard: ["agéndame el dentista", "sí pero a las cinco"])
        let runner = CarApprovalRunner(router: rig.confirmRouter())
        rig.readiness = .ready(runner: runner, sessionId: "s1")
        rig.conversation.talk()
        await rig.settle()
        #expect(runner.decisions.value == [false])
        #expect(rig.log.spoken.contains(CarPlayTurn.amendText))
        #expect(CarPlayTurn.Answer.approve.feedback == nil)
        #expect(CarPlayTurn.Answer.deny.feedback == nil)
    }

    // Reconectar mientras el turno anterior aún cierra: Hablar queda encolado.
    @Test func hablarMientrasElTurnoAnteriorCierraSeEncola() async {
        let runner = SiriGatedRunner([.textDelta("Nunca llega.")], gated: true)
        let rig = CarRig(runner: runner, heard: ["primero", "segundo"])
        rig.conversation.talk()
        await rig.waitFor { runner.started.value }
        rig.conversation.disconnect()
        rig.voice.transcripts.mutate { $0 = ["segundo"] }   // el doble vacía su guion al cancelar
        rig.conversation.talk()                   // el carro reconectó y el conductor tocó Hablar
        #expect(rig.conversation.phase == .thinking)
        await rig.waitFor { rig.voice.captures.value == 2 && runner.received.value.count == 2 }
        runner.open()
        await rig.settle()
        #expect(rig.voice.captures.value == 2)
        #expect(runner.received.value.count == 2)
    }

    // Control: Hablar en medio de una conversación viva NO se encola.
    @Test func hablarDuranteUnaConversacionVivaNoSeEncola() async {
        let runner = MockRunner()
        runner.replies.mutate { $0 = [[.textDelta("Hecho.")]] }
        let rig = CarRig(runner: runner)
        rig.voice.holdOpen.mutate { $0 = true }
        rig.conversation.talk()
        await rig.waitFor { rig.conversation.phase == .listening }
        rig.conversation.talk()
        rig.voice.finish()
        await rig.settle()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.voice.captures.value == 1)
    }

    // Choque con las gafas: si responden las gafas, el "ocupado" del carro no toca la sesión.
    @Test func ocupadoPorLasGafasNoTocaElAudio() async throws {
        let rig = CarRig(runner: MockRunner())
        let glasses = try #require(rig.gate.begin(.glassesHUD))
        rig.conversation.talk()
        await rig.settle()
        #expect(rig.log.entries.value.isEmpty)   // ni on ni off
        #expect(rig.voice.captures.value == 0)
        rig.gate.end(glasses)
        #expect(!CarPlayConversation.mayTouchAudio(whileHeldBy: .glassesHUD))
        #expect(CarPlayConversation.mayTouchAudio(whileHeldBy: .siri))
        #expect(CarPlayConversation.mayTouchAudio(whileHeldBy: nil))
    }

    @Test func lasGafasNoEscuchanMientrasElCarroTieneElTurno() async throws {
        let runtime = MockRuntime()
        let body = await readyBody(runtime)
        let voice = MockVoice()
        voice.transcripts.mutate { $0 = ["hola"] }
        let gate = TurnGate()
        let surface = GlassesHUDSurface(body: body, runner: MockRunner(), gate: gate, sessionId: "s1", voice: voice,
                                        speech: voice)
        await surface.start()
        try? await body.ensureActive()
        _ = await body.waitUntilActive()
        let car = try #require(gate.begin(.carplay))
        await surface.handle(.action(.talk))
        #expect(surface.state.screen == .trouble(heading: VoiceCaptureFailure.heading,
                                                 message: TurnGate.busyText(.carplay)))
        #expect(voice.transcripts.value == ["hola"])     // la captura no corrió
        gate.end(car)
        // Control: con la compuerta libre, escucha.
        await surface.handle(.action(.back))
        await surface.handle(.action(.talk))
        #expect(await eventually { await surface.state.screen == .heard(transcript: "hola") })
        surface.stop()
    }

    // "Autorizar siempre" jamás cubre un borrado, y desde Siri/CarPlay lo riesgoso se niega aunque esté autorizado.
    @Test func autorizarSiempreNoCubreBorradosNiSiriNiCarPlay() async {
        let ran = Locked(0)
        let asked = Locked<[String]>([])
        struct Asking: ConfirmationProvider {
            let asked: Locked<[String]>
            func confirm(_ request: ConfirmationRequest) async -> Bool {
                asked.mutate { $0.append("\(request.surface.rawValue):\(request.summary)") }
                return true
            }
        }
        let allowed: Set<AllowlistEntry> = [AllowlistEntry(tool: "calendar", operation: "delete"),
                                            AllowlistEntry(tool: "calendar", operation: "create"),
                                            AllowlistEntry(tool: "camera", operation: "default")]
        let carplay = CarPlayApprovals()
        let router = SurfaceConfirmationRouter(phone: Asking(asked: asked), glasses: nil, siri: Asking(asked: asked),
                                               carplay: carplay)
        let motor = Sensorimotor(tools: [FollowupTool(name: "calendar", ran: ran), FollowupTool(name: "camera", ran: ran)],
                                 policy: .app(ownerAllowlist: { allowed }), confirmation: router)
        let delete = JSONValue.object(["action": .string("delete")])
        let create = JSONValue.object(["action": .string("create")])
        // Chat: el borrado "autorizado siempre" igual pregunta.
        #expect(await motor.execute(name: "calendar", input: delete).content == "hecho")
        #expect(asked.value == ["phoneChat:calendar delete"])
        // Siri: el borrado se niega aunque esté autorizado.
        let siri = await motor.execute(name: "calendar", input: delete, surface: .siri)
        #expect(siri.content == CarPlayTurn.siriDestructiveRefusal)
        // CarPlay: borrado y cámara autorizados ⇒ negados igual (y pendientes).
        let car = await motor.execute(name: "calendar", input: delete, surface: .carplay)
        #expect(car.isRejection)
        let camera = await motor.execute(name: "camera", input: .object([:]), surface: .carplay)
        #expect(camera.isRejection)
        #expect(carplay.takePending() == ["calendar delete", "camera default"])
        #expect(ran.value == 1)
        // Control: lo no destructivo autorizado sigue corriendo sin preguntar (chat, Siri y carro).
        #expect(await motor.execute(name: "calendar", input: create).content == "hecho")
        #expect(await motor.execute(name: "calendar", input: create, surface: .siri).content == "hecho")
        #expect(await motor.execute(name: "calendar", input: create, surface: .carplay).content == "hecho")
        #expect(asked.value.count == 1)
        #expect(ran.value == 4)
    }

    @Test func autorizarSiempreNoGuardaBorrados() {
        let defaults = UserDefaults(suiteName: "carplay-followup-\(UUID().uuidString)")!
        let store = AuthorizedActionsStore(defaults: defaults)
        store.allow(AllowlistEntry(tool: "calendar", operation: "delete"))
        store.allow(AllowlistEntry(tool: "calendar", operation: "create"))
        #expect(store.entries == [AllowlistEntry(tool: "calendar", operation: "create")])
        #expect(!AuthorizedActionsStore.canAlwaysAllow(AllowlistEntry(tool: "calendar", operation: "delete")))
        // Lo interno y reversible de Anima no es "destructivo".
        #expect(!PermissionPolicy.isDestructive(tool: "anima_reminders", operation: "cancel"))
        #expect(PermissionPolicy.isDestructive(tool: "calendar", operation: "delete"))
        // Una entrada vieja guardada a mano no permite el borrado.
        let policy = PermissionPolicy.app(ownerAllowlist: { [AllowlistEntry(tool: "calendar", operation: "delete")] })
        #expect(policy.decide(tool: "calendar", known: true, kind: .efferent, operation: "delete") == .ask)
    }

    @Test func elSheetNoGuardaSiempreUnBorrado() {
        let center = ConfirmationCenter()
        var saved: [ConfirmationRequest] = []
        center.onAlwaysAllow = { saved.append($0) }
        center.pending = ConfirmationRequest(tool: "calendar", operation: "delete", summary: "x", input: .null)
        center.resolve(.always)
        #expect(saved.isEmpty)
        center.pending = ConfirmationRequest(tool: "calendar", operation: "create", summary: "y", input: .null)
        center.resolve(.always)
        #expect(saved.map(\.operation) == ["create"])
    }
}

private struct FollowupTool: SensorimotorTool {
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
