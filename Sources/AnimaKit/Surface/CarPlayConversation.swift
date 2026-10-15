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
    private let onPending: @MainActor ([String]) -> Void
    private var onPhase: @MainActor (CarPlayPhase) -> Void

    private var interaction: Task<Void, Never>?
    /// "Callar": lo que falte del turno no se dice (queda en el chat).
    private var muted = false
    /// Lo que se va diciendo del turno en curso (por oración, con tope).
    private var turnScript = SpokenScript()
    private var streaming = false
    /// Un turno corre en el loop (entre oraciones se ve "Pensando…").
    private var turnRunning = false
    /// Se pidió Hablar mientras un turno callado terminaba: arranca al cerrar.
    private var talkAfter = false

    // TTS por oración: cola en orden, una utterance a la vez.
    private var utterances: [String] = []
    private var speakTask: Task<Void, Never>?
    private var speechGeneration = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    // El "sí / no" de una confirmación.
    private var answer: CheckedContinuation<Bool, Never>?
    private var answerTask: Task<Void, Never>?
    private var answerTimer: Task<Void, Never>?

    public init(readiness: @escaping @MainActor () async -> Readiness, gate: TurnGate,
                gateRetry: Duration = .milliseconds(1500),
                voice: any VoiceCapturePort, answerVoice: (any VoiceCapturePort)? = nil,
                speech: any SpeechOutputPort, audio: any CarPlayAudioPort = SilentCarPlayAudio(),
                approvals: CarPlayApprovals, router: SurfaceRouter? = nil,
                confirmTimeout: Duration = CarPlayTurn.confirmTimeout,
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
    public func talk() {
        if interaction != nil {
            // Un turno callado aún termina en el chat: se habla al cerrarlo.
            if muted, phase == .idle {
                talkAfter = true
                phase = .thinking
            }
            return
        }
        muted = false
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

    // MARK: - La interacción

    private func converse() async {
        let ready = await readiness()
        guard !Task.isCancelled else { return }
        guard case .ready(let runner, let sessionId) = ready else {
            if case .blocked(let why) = ready { await say(why) }
            return
        }
        if let holder = gate.current, holder != .carplay {
            await say(CarPlayTurn.busyText(holder))
            return
        }
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

    private func finished() async {
        if !muted { await drain() }
        stopSpeech()
        releaseAudio()
        interaction = nil
        muted = false
        phase = .idle
        if talkAfter {
            talkAfter = false
            talk()
        }
    }

    /// El turno por el loop normal, marcado `.carplay`, con la compuerta tomada
    /// ANTES de espejar nada.
    private func runTurn(_ text: String, runner: any TurnRunner, sessionId: SessionID) async {
        phase = .thinking
        guard let token = await gate.acquire(.carplay, retrying: gateRetry) else {
            if !Task.isCancelled { await say(CarPlayTurn.busyText(gate.current)) }
            return
        }
        guard !Task.isCancelled else {
            gate.end(token)
            return
        }
        approvals.open()
        turnRunning = true
        defer { turnRunning = false }
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
        await gate.end(token, after: runner)
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
        let approved = await listenForAnswer()
        if phase == .confirming { phase = muted ? .idle : .thinking }
        return approved && !muted
    }

    private func listenForAnswer() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            answer = continuation
            let voice = answerVoice
            answerTask = Task { [weak self] in
                let heard = await Self.listen(voice, onFailure: { _ in })
                guard !Task.isCancelled else { return }
                self?.resolveAnswer(heard.flatMap(CarPlayTurn.parseAnswer) ?? false)
            }
            let limit = confirmTimeout
            answerTimer = Task { [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                self?.resolveAnswer(false)
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
        guard let continuation = answer else { return }
        answer = nil
        answerTask?.cancel()
        answerTask = nil
        answerTimer?.cancel()
        answerTimer = nil
        answerVoice.cancel()
        continuation.resume(returning: approved)
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
        guard !muted else { return }
        for raw in list {
            let clean = CarPlayTurn.utterance(raw)
            if !clean.isEmpty { utterances.append(clean) }
        }
        guard !utterances.isEmpty else { return }
        if phase == .thinking || phase == .listening || phase == .idle { phase = .speaking }
        pump()
    }

    private func pump() {
        guard speakTask == nil else { return }
        guard !utterances.isEmpty else {
            if phase == .speaking, turnRunning { phase = .thinking }
            let waiters = drainWaiters
            drainWaiters = []
            waiters.forEach { $0.resume() }
            return
        }
        let next = utterances.removeFirst()
        let generation = speechGeneration
        let speech = self.speech
        speakTask = Task { [weak self] in
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
        if phase == .speaking, turnRunning { phase = .thinking }
        let waiters = drainWaiters
        drainWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: - Audio

    private func activateAudio() -> Bool {
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
