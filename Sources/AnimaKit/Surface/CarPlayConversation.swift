// CarPlayConversation.swift — la superficie `.carplay`: una conversación por voz
// con Anima en el carro, sobre el MISMO loop y sesión que el chat.
//   Hablar → (sesión de audio) escuchar → turno por la compuerta (uno a la vez,
//   espejo en el chat con chip "CarPlay") → la respuesta se DICE por oración
//   mientras llega (StreamingSentenceSegmenter vía SpokenScript, tope hablado y
//   remisión al chat) → soltar la sesión de audio → reposo.
// Las confirmaciones de tools se preguntan en voz ("¿Lo hago? Di sí o no") y
// también con los botones Sí/No del template; lo de riesgo y la cámara de las
// gafas se niegan sin preguntar (CarPlayTurn.refusal). Es puro + puertos: el
// shell (App/CarPlay) solo proyecta `phase` al CPVoiceControlTemplate y le
// entrega los taps.

import Foundation

@MainActor
public final class CarPlayConversation: Surface {
    public enum Readiness: Sendable {
        case ready(runner: any TurnRunner, sessionId: SessionID)
        /// No se puede conversar ahora (sin onboarding, sin red, sin key…): qué decir.
        case blocked(String)
    }

    public let id = SurfaceID.carplay
    public let capabilities = SurfaceCapabilities.carplay
    public let events: AsyncStream<SurfaceEvent>
    private let sink: AsyncStream<SurfaceEvent>.Continuation

    public private(set) var phase: CarPlayPhase = .idle {
        didSet { if phase != oldValue { onPhase(phase) } }
    }
    /// ¿Hay una interacción en curso (aunque se haya callado)?
    public var isBusy: Bool { interaction != nil }
    /// La sesión de audio está tomada (solo mientras se usa la voz).
    public private(set) var audioActive = false

    private let readiness: @MainActor () async -> Readiness
    private let gate: TurnGate
    private let gateRetry: Duration
    private let voice: any VoiceCapturePort
    private let answerVoice: any VoiceCapturePort
    private let speech: any SpeechOutputPort
    private let audio: any CarPlayAudioPort
    private let approvals: CarPlayApprovals
    private weak var router: SurfaceRouter?
    private let confirmTimeout: Duration
    private let relistenPause: Duration
    private let onPending: @MainActor ([String]) -> Void
    private var onPhase: @MainActor (CarPlayPhase) -> Void

    private var interaction: Task<Void, Never>?
    /// "Callar": lo que falte del turno no se dice (queda en el chat).
    private var muted = false
    /// Lo que se va diciendo del turno en curso (por oración, con tope).
    private var turnScript = SpokenScript()
    private var streaming = false
    /// Se pidió Hablar mientras la interacción anterior terminaba (callada,
    /// cancelada o tras reconectar el carro): arranca al cerrarla.
    private var talkAfter = false
    /// cancel()/disconnect() ya cortaron: la interacción solo está cerrando.
    private var closing = false
    /// La compuerta, tomada para TODA la interacción (escuchar + turno + voz):
    /// mientras el carro usa el micrófono o habla, ninguna otra superficie
    /// corre un turno ni las gafas abren su captura.
    private var token: TurnGate.Token?
    /// El loop que corrió el turno (la compuerta se suelta cuando deja de producir).
    private var ranOn: (any TurnRunner)?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    // TTS por oración: cola en orden, una utterance a la vez.
    private var utterances: [String] = []
    private var speakTask: Task<Void, Never>?
    private var speechGeneration = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    // El "sí / no" de una confirmación.
    private var answer: CheckedContinuation<CarPlayTurn.Answer, Never>?
    private var answerTask: Task<Void, Never>?
    private var answerTimer: Task<Void, Never>?

    public init(readiness: @escaping @MainActor () async -> Readiness, gate: TurnGate,
                gateRetry: Duration = .milliseconds(1500),
                voice: any VoiceCapturePort, answerVoice: (any VoiceCapturePort)? = nil,
                speech: any SpeechOutputPort, audio: any CarPlayAudioPort = SilentCarPlayAudio(),
                approvals: CarPlayApprovals, router: SurfaceRouter? = nil,
                confirmTimeout: Duration = CarPlayTurn.confirmTimeout,
                relistenPause: Duration = CarPlayTurn.relistenPause,
                onPending: @escaping @MainActor ([String]) -> Void = { _ in },
                onPhase: @escaping @MainActor (CarPlayPhase) -> Void = { _ in }) {
        self.readiness = readiness
        self.gate = gate
        self.gateRetry = gateRetry
        self.voice = voice
        self.answerVoice = answerVoice ?? voice
        self.speech = speech
        self.audio = audio
        self.approvals = approvals
        self.router = router
        self.confirmTimeout = confirmTimeout
        self.relistenPause = relistenPause
        self.onPending = onPending
        self.onPhase = onPhase
        (events, sink) = AsyncStream<SurfaceEvent>.makeStream()
        approvals.setAsk { [weak self] request in
            await self?.confirm(request) ?? false
        }
        router?.register(self)
    }

    /// El shell reemplaza al observador cuando el template se re-crea.
    public func observe(_ handler: @escaping @MainActor (CarPlayPhase) -> Void) {
        onPhase = handler
        handler(phase)
    }

    // MARK: - Entradas

    public func tapped(_ button: CarPlayButton) {
        switch button {
        case .talk: talk()
        case .done: voice.finish()
        case .cancel: cancel()
        case .stop: hush()
        case .yes: resolveAnswer(true)
        case .no: resolveAnswer(false)
        }
    }

    /// "Hablar" (o abrir Anima en el carro): una interacción de voz completa.
    /// Si la anterior aún cierra (callada, cancelada, o el carro se reconectó
    /// antes de que terminara), queda encolada y arranca al cerrarla.
    public func talk() {
        if interaction != nil {
            if muted || closing {
                talkAfter = true
                if phase == .idle { phase = .thinking }
            }
            return
        }
        muted = false
        closing = false
        talkAfter = false
        interaction = Task { [weak self] in
            await self?.converse()
            await self?.finished()
        }
    }

    /// Corta todo: la escucha, la voz, la confirmación pendiente (se niega) y el
    /// turno (el chat lo cierra como interrumpido).
    public func cancel() {
        talkAfter = false
        if interaction != nil { closing = true }
        interaction?.cancel()
        voice.cancel()
        approvals.close()
        resolveAnswer(false)
        stopSpeech()
    }

    /// CarPlay se desconectó (el carro se apagó o se fue a otra app): se corta.
    public func disconnect() {
        cancel()
        releaseAudio()
        phase = .idle
    }

    /// "Callar": deja de hablar ya y suelta el audio; el resto del turno sigue y
    /// queda en el chat. Lo que pida confirmación después se niega.
    public func hush() {
        guard interaction != nil else { return }
        muted = true
        resolveAnswer(false)
        stopSpeech()
        releaseAudio()
        phase = .idle
    }

    /// Vuelve cuando no hay interacción (ni una cerrándose).
    public func waitUntilIdle() async {
        guard interaction != nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: - La interacción

    private func converse() async {
        let ready = await readiness()
        guard !Task.isCancelled else { return }
        guard case .ready(let runner, let sessionId) = ready else {
            if case .blocked(let why) = ready { await say(why) }
            return
        }
        // La compuerta ANTES del micrófono (reintenta si la suelta un turno de
        // CarPlay que aún cierra).
        guard let token = await gate.acquire(.carplay, retrying: gateRetry) else {
            guard !Task.isCancelled else { return }
            let holder = gate.current
            // Las gafas usan la MISMA sesión de audio: no se toca (ni se activa
            // ni se suelta) mientras sean ellas las que responden.
            if Self.mayTouchAudio(whileHeldBy: holder) { await say(CarPlayTurn.busyText(holder)) }
            return
        }
        self.token = token
        guard !Task.isCancelled else { return }
        guard activateAudio() else {
            await say(CarPlayTurn.voiceFailureText(.engineFailed("sesión de audio")))
            return
        }
        phase = .listening
        let failure = GlassesBox<VoiceCaptureFailure?>(nil)
        let heard = await Self.listen(voice, onFailure: { failure.value = $0 })
        guard !Task.isCancelled else { return }
        let text = heard?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            await say(failure.value.map(CarPlayTurn.voiceFailureText) ?? CarPlayTurn.emptyText)
            return
        }
        sink.yield(.voiceTranscript(text))
        await runTurn(text, runner: runner, sessionId: sessionId)
    }

    /// ¿Puede el carro usar la sesión de audio mientras `holder` tiene el turno?
    /// Las gafas capturan y hablan por la misma sesión del proceso.
    nonisolated static func mayTouchAudio(whileHeldBy holder: SurfaceID?) -> Bool {
        holder != .glassesHUD
    }

    private func finished() async {
        if !muted { await drain() }
        stopSpeech()
        releaseAudio()
        if let token {
            self.token = nil
            if let runner = ranOn { await gate.end(token, after: runner) } else { gate.end(token) }
        }
        ranOn = nil
        interaction = nil
        muted = false
        closing = false
        phase = .idle
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
        if talkAfter {
            talkAfter = false
            talk()
        }
    }

    /// El turno por el loop normal, marcado `.carplay` (la compuerta ya es suya).
    private func runTurn(_ text: String, runner: any TurnRunner, sessionId: SessionID) async {
        phase = .thinking
        approvals.open()
        ranOn = runner
        await deliver(.userTurn(text: text, origin: .carplay))
        var collector = SiriTurnCollector()
        turnScript = Self.script()
        streaming = true
        let stream = await runner.run(sessionId: sessionId, content: [AudioTool.transcriptBlock(text)],
                                      surface: .carplay)
        for await event in stream {
            collector.apply(event)
            switch event {
            case .textDelta(let delta):
                if collector.refused { streaming = false }
                if streaming { enqueue(turnScript.feed(delta)) }
            case .retracted:
                // Lo retraído no se sigue diciendo: la respuesta corregida se dice entera al cerrar.
                stopSpeech()
                turnScript = Self.script()
                streaming = false
            default:
                break
            }
        }
        approvals.close()
        if Task.isCancelled {
            stopSpeech()
            await deliver(collector.started ? .turnFailed(text: CarPlayTurn.interruptedText, origin: .carplay)
                                            : .turnDropped(origin: .carplay))
        } else {
            let outcome = collector.outcome
            switch outcome {
            case .replied(let reply), .declined(let reply):
                if streaming { enqueue(turnScript.finish()) }
                if !streaming || turnScript.utterances.isEmpty {
                    stopSpeech()
                    var whole = Self.script()
                    enqueue(whole.feed(reply) + whole.finish())
                }
            case .failed:
                stopSpeech()
                enqueue([SiriTurn.spoken(outcome)])
            default:
                break
            }
            if let mirror = SiriTurnCollector.mirror(outcome, origin: .carplay) { await deliver(mirror) }
        }
        let pending = approvals.takePending()
        if !pending.isEmpty { onPending(pending) }
    }

    private static func script() -> SpokenScript {
        SpokenScript(limit: CarPlayTurn.spokenLimit, tail: CarPlayTurn.chatTail)
    }

    /// Origen + espejo en el teléfono.
    private func deliver(_ content: SurfaceContent) async {
        await router?.route(content)
    }

    // MARK: - Confirmación en el carro

    /// Lo que pide el ok del dueño: se dice la acción, se escucha "sí / no" y
    /// también valen los botones. Callado, cortado o sin respuesta ⇒ no.
    func confirm(_ request: ConfirmationRequest) async -> Bool {
        guard !muted, audioActive, interaction != nil else { return false }
        // Lo que Anima alcanzó a decir antes de la tool se dice primero: el
        // consumidor del stream (también en el main actor) alcanza los deltas
        // ya emitidos antes de que se cierre la frase pendiente.
        for _ in 0..<8 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
        if streaming { enqueue(turnScript.flush()) }
        await drain()
        guard !muted, approvals.isOpen else { return false }
        phase = .confirming
        enqueue([CarPlayTurn.confirmationPrompt(request.summary)])
        await drain()
        guard !muted, approvals.isOpen else {
            if phase == .confirming { phase = .thinking }
            return false
        }
        let answer = await listenForAnswer()
        if phase == .confirming { phase = muted ? .idle : .thinking }
        if !muted, approvals.isOpen, let feedback = answer.feedback { enqueue([feedback]) }
        return answer.approves && !muted
    }

    /// La ventana entera (`confirmTimeout`) para el "sí / no": si una escucha
    /// vuelve vacía (silencio, tope de la captura, mic que falla) se vuelve a
    /// escuchar; los botones Sí/No valen hasta que vence.
    private func listenForAnswer() async -> CarPlayTurn.Answer {
        await withCheckedContinuation { (continuation: CheckedContinuation<CarPlayTurn.Answer, Never>) in
            answer = continuation
            let voice = answerVoice
            let pause = relistenPause
            answerTask = Task { [weak self] in
                var micBroken = false
                while !Task.isCancelled, !micBroken {
                    let failed = GlassesBox(false)
                    let heard = await Self.listen(voice, onFailure: { _ in failed.value = true })
                    guard !Task.isCancelled else { return }
                    let said = heard?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !said.isEmpty {
                        self?.resolveAnswer(CarPlayTurn.answer(said))
                        return
                    }
                    // Sin micrófono no se insiste: quedan los botones hasta el tope.
                    micBroken = failed.value
                    try? await Task.sleep(for: pause)
                }
            }
            let limit = confirmTimeout
            answerTimer = Task { [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                self?.resolveAnswer(CarPlayTurn.Answer.deny)
            }
        }
    }

    /// Una captura que se corta con la tarea: una cancelación que llega justo
    /// antes de que la captura arranque (y resetee su estado) no se pierde —
    /// se repite hasta que la captura vuelve.
    nonisolated static func listen(_ voice: any VoiceCapturePort,
                                   onFailure: @escaping @Sendable (VoiceCaptureFailure) -> Void) async -> String? {
        let done = GlassesBox(false)
        return await withTaskCancellationHandler {
            let heard = await voice.capture(onRoute: { _ in }, onPartial: { _ in }, onFailure: onFailure)
            done.value = true
            return heard
        } onCancel: {
            Task {
                while !done.value {
                    voice.cancel()
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
    }

    private func resolveAnswer(_ approved: Bool) {
        resolveAnswer(approved ? CarPlayTurn.Answer.approve : .deny)
    }

    private func resolveAnswer(_ value: CarPlayTurn.Answer) {
        guard let continuation = answer else { return }
        answer = nil
        answerTask?.cancel()
        answerTask = nil
        answerTimer?.cancel()
        answerTimer = nil
        answerVoice.cancel()
        continuation.resume(returning: value)
    }

    // MARK: - Voz

    /// Dice un texto suelto (ocupado, sin red, no te escuché…) con la sesión de
    /// audio tomada solo mientras habla.
    private func say(_ text: String) async {
        guard activateAudio() else { return }
        enqueue([text])
        await drain()
    }

    private func enqueue(_ list: [String]) {
        // Callado o cortado (cancelar, desconectar, background): no se dice nada más.
        guard !muted, !closing else { return }
        for raw in list {
            let clean = CarPlayTurn.utterance(raw)
            if !clean.isEmpty { utterances.append(clean) }
        }
        guard !utterances.isEmpty else { return }
        // Una vez que habla, queda "respondiendo" hasta el final de la respuesta
        // (no se alterna por oración: el template limita la frecuencia de cambios).
        if phase != .speaking, phase != .confirming { phase = .speaking }
        pump()
    }

    private func pump() {
        guard speakTask == nil else { return }
        guard !utterances.isEmpty else {
            let waiters = drainWaiters
            drainWaiters = []
            waiters.forEach { $0.resume() }
            return
        }
        let next = utterances.removeFirst()
        let generation = speechGeneration
        let speech = self.speech
        speakTask = Task { [weak self] in
            // Cortada antes de arrancar (stopSpeech): no se dice.
            guard !Task.isCancelled else { return }
            await speech.speak(next)
            self?.spoke(generation)
        }
    }

    private func spoke(_ generation: Int) {
        guard generation == speechGeneration else { return }
        speakTask = nil
        pump()
    }

    /// Espera a que la cola de voz se vacíe.
    private func drain() async {
        guard speakTask != nil || !utterances.isEmpty else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    private func stopSpeech() {
        speechGeneration += 1
        utterances = []
        speakTask?.cancel()
        speakTask = nil
        speech.stop()
        let waiters = drainWaiters
        drainWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: - Audio

    private func activateAudio() -> Bool {
        guard !closing else { return false }
        guard !audioActive else { return true }
        do {
            try audio.activateConversation()
            audioActive = true
            return true
        } catch {
            return false
        }
    }

    private func releaseAudio() {
        guard audioActive else { return }
        audioActive = false
        audio.releaseConversation()
    }

    // MARK: - Surface

    /// El carro no espeja turnos de otras superficies (solo dice los suyos).
    public func render(_ content: SurfaceContent) async {}
}
