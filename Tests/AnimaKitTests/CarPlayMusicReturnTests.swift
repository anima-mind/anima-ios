import Foundation
import Testing
@testable import AnimaKit

// Campo (#51): tras usar Anima en el carro la música no volvía hasta reiniciar
// el carro. `setActive(false)` falla con I/O en curso (el engine de la captura
// que aún no para, la cola del sintetizador) y el error se tragaba con `try?`:
// la sesión quedaba activa en .playAndRecord sin mezcla. Cada camino verifica la
// sesión del doble (activa = false, notifyOthers usado) y tiene su control
// negativo con el comportamiento anterior.

// MARK: - Dobles con I/O

/// El reconocedor real visto desde la sesión: mientras corre hay I/O. Sin
/// `stopsEngine` es el teardown que olvida `engine.stop` / `removeTap`.
final class IORecognizer: SpeechRecognitionPort, @unchecked Sendable {
    let control: FakeAudioControl
    let stopsEngine: Bool
    let words: String?
    private let running = Locked(false)

    init(_ control: FakeAudioControl, stopsEngine: Bool = true, words: String? = nil) {
        self.control = control
        self.stopsEngine = stopsEngine
        self.words = words
    }

    func start(onPartial: @escaping @Sendable (String) -> Void) throws {
        running.mutate { $0 = true }
        control.io.mutate { $0 += 1 }
        if let words { onPartial(words) }
    }

    func stop() {
        guard stopsEngine, running.mutate({ was -> Bool in defer { was = false }; return was }) else { return }
        control.io.mutate { $0 -= 1 }
    }
}

/// La captura de las gafas (VoiceCaptureLoop) con el reconocedor de arriba.
final class IOLoopVoice: VoiceCapturePort, @unchecked Sendable {
    let loop: VoiceCaptureLoop
    let make: @Sendable () -> IORecognizer
    let running = Locked(false)

    init(audio: any AudioSessionPort, silence: TimeInterval = 30, make: @escaping @Sendable () -> IORecognizer) {
        loop = VoiceCaptureLoop(audio: audio, detector: TurnEndDetector(silence: silence, maxDuration: 30),
                                settle: 0, poll: 0.005)
        self.make = make
    }

    func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void) async -> String? {
        running.mutate { $0 = true }
        defer { running.mutate { $0 = false } }
        let make = self.make
        return await loop.run(recognizer: { make() }, onRoute: onRoute)
    }

    func cancel() { loop.cancel() }
    func finish() { loop.finish() }
}

/// AVSpeechSynthesizer visto desde la sesión: hay I/O mientras habla y un rato
/// después de terminar o de `stopSpeaking` (`tail`). Con `holds`, habla hasta `stop`.
final class TailSpeaker: SpeechOutputPort, @unchecked Sendable {
    let audio: any AudioSessionPort
    let control: FakeAudioControl
    let tail: Duration
    let holds = Locked(false)
    let spoken = Locked<[String]>([])
    private let speaking = Locked(false)

    init(audio: any AudioSessionPort, control: FakeAudioControl, tail: Duration = .milliseconds(40)) {
        self.audio = audio
        self.control = control
        self.tail = tail
    }

    func speak(_ text: String) async {}

    func speak(_ text: String, line: SpeechLine, ticket: SpeechLine.Ticket) async {
        do {
            try audio.activatePlaybackA2DP()
        } catch is AudioSessionNotOwned {
            return
        } catch {}
        guard line.perform(ticket, { begin(text) }) else { return }
        try? await Task.sleep(for: .milliseconds(5))
        while holds.value, speaking.value { try? await Task.sleep(for: .milliseconds(2)) }
        end()
    }

    func stop() { end() }

    private func begin(_ text: String) {
        spoken.mutate { $0.append(text) }
        speaking.mutate { $0 = true }
        control.io.mutate { $0 += 1 }
    }

    private func end() {
        guard speaking.mutate({ was -> Bool in defer { was = false }; return was }) else { return }
        let tail = self.tail, control = self.control
        Task.detached {
            try? await Task.sleep(for: tail)
            control.io.mutate { $0 -= 1 }
        }
    }
}

private let fastBackoff: [Duration] = [10, 20, 40, 80, 160, 320].map { .milliseconds($0) }

@MainActor
private final class MusicRig {
    let control = FakeAudioControl()
    let gate = TurnGate()
    let runner: any TurnRunner
    let audio: any CarPlayAudioPort & AudioSessionPort
    let owner: CarPlayAudioSessionOwner?
    let voice: IOLoopVoice
    let speaker: TailSpeaker
    private(set) var conversation: CarPlayConversation!

    init(legacy: Bool = false, retryDelays: [Duration] = fastBackoff, silence: TimeInterval = 0.04,
         stopsEngine: Bool = true, runner: (any TurnRunner)? = nil) {
        if let runner {
            self.runner = runner
        } else {
            let mock = MockRunner()
            mock.replies.mutate { $0 = [[.textDelta("Hola, Joshua.")]] }
            self.runner = mock
        }
        if legacy {
            audio = LegacyCarPlayAudio(control)
            owner = nil
        } else {
            let owner = CarPlayAudioSessionOwner(control: control, retryDelays: retryDelays)
            audio = owner
            self.owner = owner
        }
        let control = self.control
        voice = IOLoopVoice(audio: audio, silence: silence) {
            IORecognizer(control, stopsEngine: stopsEngine, words: "qué tengo mañana")
        }
        speaker = TailSpeaker(audio: audio, control: control)
        let runner = self.runner
        conversation = CarPlayConversation(readiness: { .ready(runner: runner, sessionId: "s1") }, gate: gate,
                                           gateRetry: .milliseconds(30), voice: voice, speech: speaker,
                                           audio: audio, approvals: CarPlayApprovals())
    }

    func lifecycle() -> CarPlaySceneLifecycle {
        CarPlaySceneLifecycle(conversation: conversation, hold: { _ in }, backgroundWork: { { } })
    }

    /// La música vuelve: sesión inactiva, se avisó a los demás y nada quedó pendiente.
    var musicBack: Bool {
        !control.active.value && control.notified.value > 0 && owner?.isReleasePending != true
            && !control.nonMixable.value
    }

    func until(_ timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
    }
}

// MARK: - Caminos de la conversación

@MainActor
@Suite("CarPlay #51 — la música del carro vuelve")
struct CarPlayMusicReturnTests {
    @Test func respuestaNormalAlQuedarEnReposoSueltaLaSesion() async {
        let rig = MusicRig()
        rig.conversation.talk()
        await rig.until { rig.speaker.spoken.value.count == 1 }
        await rig.conversation.waitUntilIdle()
        #expect(rig.conversation.phase == .idle)
        await rig.until { rig.musicBack }
        #expect(rig.musicBack)
        // El primer setActive(false) chocó con la cola del sintetizador y se reintentó.
        #expect(rig.control.ops.value.contains("busy"))
        #expect(rig.control.ops.value.last == "off+notify")
    }

    // CONTROL NEGATIVO: el `try?` de antes — un solo intento con I/O en curso — la deja activa.
    @Test func controlNegativoSinReintentoQuedaActiva() async {
        let rig = MusicRig(legacy: true)
        rig.conversation.talk()
        await rig.until { rig.speaker.spoken.value.count == 1 }
        await rig.conversation.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.control.active.value)
        #expect(rig.control.notified.value == 0)
    }

    @Test func callarMientrasHablaSueltaLaSesion() async {
        let rig = MusicRig()
        rig.speaker.holds.mutate { $0 = true }
        rig.conversation.talk()
        await rig.until { rig.conversation.phase == .speaking && rig.control.io.value > 0 }
        rig.conversation.tapped(.stop)
        #expect(rig.conversation.phase == .idle)
        await rig.until { rig.musicBack }
        #expect(rig.musicBack)
        await rig.conversation.waitUntilIdle()
        #expect(rig.musicBack)
    }

    @Test func controlNegativoCallarSinReintentoQuedaActiva() async {
        let rig = MusicRig(legacy: true)
        rig.speaker.holds.mutate { $0 = true }
        rig.conversation.talk()
        await rig.until { rig.conversation.phase == .speaking && rig.control.io.value > 0 }
        rig.conversation.tapped(.stop)
        await rig.conversation.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.control.active.value)
    }

    @Test func cancelarEscuchandoSueltaLaSesion() async {
        let rig = MusicRig(silence: 30)
        rig.conversation.talk()
        await rig.until { rig.conversation.phase == .listening && rig.control.io.value == 1 }
        rig.conversation.tapped(.cancel)
        await rig.conversation.waitUntilIdle()
        await rig.until { rig.musicBack }
        #expect(rig.musicBack)
        #expect(rig.control.io.value == 0)
    }

    // Sin timers de reintento: la suelta el aviso del teardown de la captura
    // (engine y tap ya parados) — no la suerte de un backoff.
    @Test func desconectarEscuchandoLaSueltaElTeardownDeLaCaptura() async {
        let rig = MusicRig(retryDelays: [], silence: 30)
        rig.conversation.talk()
        await rig.until { rig.conversation.phase == .listening && rig.control.io.value == 1 }
        rig.conversation.disconnect()
        #expect(rig.owner?.isReleasePending == true)    // el engine seguía corriendo: falló
        await rig.until { !rig.voice.running.value }
        await rig.until { rig.musicBack }
        #expect(rig.musicBack)
        #expect(rig.control.ops.value.contains("busy"))
    }

    // CONTROL NEGATIVO: la captura que no para su engine (engine.stop/removeTap
    // faltantes) mantiene el I/O y la sesión jamás se puede soltar.
    @Test func controlNegativoEngineQueNoParaDejaLaSesionActiva() async {
        let rig = MusicRig(retryDelays: [], silence: 30, stopsEngine: false)
        rig.conversation.talk()
        await rig.until { rig.conversation.phase == .listening && rig.control.io.value == 1 }
        rig.conversation.disconnect()
        await rig.until { !rig.voice.running.value }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.control.active.value)
        #expect(rig.owner?.isReleasePending == true)
    }

    @Test func salirDeAnimaPensandoSueltaLaSesion() async {
        let runner = SiriGatedRunner([.textDelta("Nunca llega.")], gated: true)
        let rig = MusicRig(runner: runner)
        let scene = rig.lifecycle()
        scene.didConnect()
        scene.didBecomeActive()
        rig.conversation.talk()
        await rig.until { runner.started.value }
        #expect(rig.control.active.value)
        scene.didEnterBackground()
        await rig.until { rig.musicBack }
        #expect(rig.musicBack)
        await rig.conversation.waitUntilIdle()
        #expect(rig.musicBack)
        #expect(!(rig.owner?.isOwned ?? true))
    }

    @Test func desconectarHablandoSueltaLaSesion() async {
        let rig = MusicRig()
        rig.speaker.holds.mutate { $0 = true }
        let scene = rig.lifecycle()
        scene.didConnect()
        rig.conversation.talk()
        await rig.until { rig.conversation.phase == .speaking && rig.control.io.value > 0 }
        scene.didDisconnect()
        await rig.until { rig.musicBack }
        #expect(rig.musicBack)
        await rig.conversation.waitUntilIdle()
        #expect(rig.musicBack)
    }

    // Otra parte de la app (el mic del chat, las gafas) dejó la sesión activa en
    // una categoría sin mezcla: salir de Anima en el carro la suelta y la restaura.
    @Test func salirDeAnimaEnReposoSueltaLoQueDejoOtraParteDeLaApp() async {
        let rig = MusicRig()
        rig.control.active.mutate { $0 = true }
        rig.control.nonMixable.mutate { $0 = true }
        let scene = rig.lifecycle()
        scene.didConnect()
        scene.didBecomeActive()
        scene.didEnterBackground()
        await rig.until { rig.musicBack }
        #expect(rig.musicBack)
        #expect(rig.control.ops.value == ["off+notify"])
    }

    // CONTROL NEGATIVO: con las gafas respondiendo (misma sesión) no se toca.
    @Test func conLasGafasRespondiendoNoSeTocaLaSesion() async {
        let rig = MusicRig()
        rig.control.active.mutate { $0 = true }
        let token = rig.gate.begin(.glassesHUD)
        let scene = rig.lifecycle()
        scene.didConnect()
        scene.didEnterBackground()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.control.active.value)
        #expect(rig.control.ops.value.isEmpty)
        if let token { rig.gate.end(token) }
    }
}

// MARK: - El dueño de la sesión

@Suite("CarPlay #51 — liberar la sesión es un deber")
struct CarPlayAudioOwnerReleaseTests {
    @Test func reintentaConBackoffHastaSoltar() async throws {
        let control = FakeAudioControl()
        let owner = CarPlayAudioSessionOwner(control: control, retryDelays: fastBackoff)
        try owner.activateConversation()
        #expect(control.nonMixable.value)
        control.busyDeactivations.mutate { $0 = 3 }
        owner.releaseConversation()
        #expect(owner.isReleasePending)
        #expect(control.active.value)
        _ = await eventually { !owner.isReleasePending }
        #expect(!control.active.value)
        #expect(control.notified.value == 1)
        #expect(!control.nonMixable.value)
        #expect(control.ops.value == ["category", "on", "busy", "busy", "busy", "off+notify"])
    }

    // CONTROL NEGATIVO: el adaptador de #41/#44 (`try?` una vez) se rinde al primer isBusy.
    @Test func controlNegativoElTryDeAntesSeRinde() async throws {
        let control = FakeAudioControl()
        let legacy = LegacyCarPlayAudio(control)
        try legacy.activateConversation()
        control.busyDeactivations.mutate { $0 = 1 }
        legacy.releaseConversation()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(control.active.value)
        #expect(control.notified.value == 0)
    }

    @Test func retomarLaSesionCancelaLosReintentos() async throws {
        let control = FakeAudioControl()
        let owner = CarPlayAudioSessionOwner(control: control, retryDelays: fastBackoff)
        try owner.activateConversation()
        control.busyDeactivations.mutate { $0 = 1 }
        owner.releaseConversation()
        try owner.activateConversation()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(control.active.value)
        #expect(owner.isOwned)
        #expect(!owner.isReleasePending)
        #expect(control.ops.value == ["category", "on", "busy", "category", "on"])
    }

    @Test func agotadosLosReintentosQuedaPendienteYElTeardownLaSuelta() async throws {
        let control = FakeAudioControl()
        let owner = CarPlayAudioSessionOwner(control: control, retryDelays: [.milliseconds(5)])
        try owner.activateConversation()
        control.io.mutate { $0 = 1 }
        owner.releaseConversation()
        try? await Task.sleep(for: .milliseconds(60))
        #expect(owner.isReleasePending)
        #expect(control.active.value)
        control.io.mutate { $0 = 0 }
        owner.deactivate()
        #expect(!owner.isReleasePending)
        #expect(!control.active.value)
        #expect(control.notified.value == 1)
        owner.deactivate()
        #expect(control.notified.value == 1)
    }

    @Test func ensureReleasedSueltaAunqueNoSeaSuya() {
        let control = FakeAudioControl()
        let owner = CarPlayAudioSessionOwner(control: control, retryDelays: [])
        control.active.mutate { $0 = true }
        control.nonMixable.mutate { $0 = true }
        owner.releaseConversation()                 // no es suya: releaseConversation no la toca
        #expect(control.active.value)
        owner.ensureReleased()
        #expect(!control.active.value)
        #expect(!control.nonMixable.value)
        #expect(control.ops.value == ["off+notify"])
        #expect(throws: AudioSessionNotOwned.self) { try owner.activatePlaybackA2DP() }
    }

    @Test func silentCarPlayAudioUsaElDefaultDeEnsureReleased() {
        SilentCarPlayAudio().ensureReleased()
    }
}

// MARK: - El mic del chat no deja la sesión en .playback activa

@Suite("Mic del composer — la sesión queda suelta")
struct PhoneMicReleaseTests {
    @Test func trasDictarNoReactivaPlayback() {
        final class Audio: AudioSessionPort, @unchecked Sendable {
            let calls = Locked<[String]>([])
            func hfpInputAvailable() -> Bool { false }
            func activateHFP() throws { calls.mutate { $0.append("hfp") } }
            func currentInputIsHFP() -> Bool { false }
            func activatePhoneMic() throws { calls.mutate { $0.append("phoneMic") } }
            func activatePlaybackA2DP() throws { calls.mutate { $0.append("a2dp") } }
            func deactivate() { calls.mutate { $0.append("off") } }
        }
        let audio = Audio()
        AudioRoutePlanner.releaseCapture(PhoneMicAudioSession(audio))
        #expect(audio.calls.value == ["off"])
        // Control: las gafas sí vuelven a A2DP para hablar.
        let glasses = Audio()
        AudioRoutePlanner.releaseCapture(glasses)
        #expect(glasses.calls.value == ["off", "a2dp"])
    }
}
