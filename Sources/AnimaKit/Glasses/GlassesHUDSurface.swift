// GlassesHUDSurface.swift — la superficie HUD (doc 05 §3.2, §4): ejecuta la
// máquina de estados del handoff contra el cuerpo real.
//   captouch/pinch en "Hablar" → HFP + STT on-device → transcript visible →
//   "Enviar" → turno por el AgentLoop NORMAL (cualquier córtex, misma sesión,
//   marca de superficie) → card con el gist + TTS por A2DP.
// Espejo en el teléfono vía SurfaceRouter: la conversación es UNA. Además es el
// host de las tools de gafas (proyectar card, cámara POV con pinch en la cara).
// Solo emite .voiceTranscript / .buttonTapped / .exited (nunca .userText).

import Foundation

/// Lo que la superficie necesita del loop (AgentLoop lo cumple).
public protocol TurnRunner: Sendable {
    func run(sessionId: SessionID, content: [ContentBlock], surface: SurfaceID) async -> AsyncStream<LoopEvent>
}

extension AgentLoop: TurnRunner {}

@MainActor
public final class GlassesHUDSurface: Surface, GlassesToolHost {
    public let id = SurfaceID.glassesHUD
    public let capabilities = SurfaceCapabilities.glassesHUD
    public let events: AsyncStream<SurfaceEvent>
    private let sink: AsyncStream<SurfaceEvent>.Continuation

    public private(set) var state = HUDConversationState()

    private let body: GlassesBody
    private let activation: GlassesActivation?
    private let runner: any TurnRunner
    private let sessionId: SessionID
    private let voice: any VoiceCapturePort
    private let speech: any SpeechOutputPort
    private weak var router: SurfaceRouter?
    private let openPhone: @MainActor (UUID?) -> Void
    private let cameraTimeout: TimeInterval
    private let errorDwell: TimeInterval

    private var listenTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    private var speakTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var homeTask: Task<Void, Never>?
    /// Karaoke: ventanas del texto que se está diciendo (solo en speaking).
    private var pager: HUDSpokenPager?
    private var speechGeneration = 0
    /// TTS por oración: la cola de utterances del turno en curso.
    private var speechSession: SpeechSession?
    private var turnGeneration = 0
    private var turnScript = SpokenScript()
    private var turnSpeechDismissed = false

    private struct SpeechSession {
        let generation: Int
        /// Turno al que pertenece (nil = texto completo, sin stream).
        let turn: Int?
        var script: SpokenScript
        let heading: String
        var lastLocation = 0
        let queue: AsyncStream<(Int, String)>.Continuation
    }
    private var cameraContinuation: CheckedContinuation<Bool, Never>?
    private var cameraRequestID = 0

    public init(body: GlassesBody, activation: GlassesActivation? = nil, runner: any TurnRunner,
                sessionId: SessionID, voice: any VoiceCapturePort, speech: any SpeechOutputPort,
                router: SurfaceRouter? = nil, cameraTimeout: TimeInterval = 60, errorDwell: TimeInterval = 4,
                openPhone: @escaping @MainActor (UUID?) -> Void = { _ in }) {
        self.body = body
        self.activation = activation
        self.runner = runner
        self.sessionId = sessionId
        self.voice = voice
        self.speech = speech
        self.router = router
        self.cameraTimeout = cameraTimeout
        self.errorDwell = errorDwell
        self.openPhone = openPhone
        (events, sink) = AsyncStream<SurfaceEvent>.makeStream()
        router?.register(self)
    }

    /// Cablea los callbacks del cuerpo y deja la Home como vista actual.
    public func start() async {
        await body.setHandlers(
            onAction: { [weak self] action in Task { @MainActor in await self?.tapped(action) } },
            onExit: { [weak self] in Task { @MainActor in await self?.exited() } })
        let updates = await body.statusUpdates()
        statusTask = Task { [weak self] in
            for await status in updates { await self?.bodyChanged(status) }
        }
        await rerender()
    }

    public func stop() {
        statusTask?.cancel()
        listenTask?.cancel()
        turnTask?.cancel()
        speakTask?.cancel()
        speechSession?.queue.finish()
        captureTask?.cancel()
        homeTask?.cancel()
        resolveCamera(false)
        sink.finish()
    }

    // MARK: - Entradas

    func tapped(_ action: HUDActionID) async {
        sink.yield(.buttonTapped(action))
        await handle(.action(action))
    }

    func exited() async {
        await activation?.userExited()
        sink.yield(.exited)
        await handle(.exited)
    }

    func bodyChanged(_ status: GlassesStatus) async {
        let line = Self.homeLine(status)
        guard line != state.status else { return }
        state.status = line
        if case .home = state.screen {
            state.screen = .home(status: line)
            await rerender()
        }
    }

    /// La línea de la Home: lo que el SDK sí reporta (la batería, si algún día llega).
    static func homeLine(_ status: GlassesStatus) -> String? {
        status.batteryPercent.map { "Batería \($0)% · toca Hablar para conversar." }
    }

    /// Un evento de la máquina de estados: reduce, re-envía si cambió la vista y
    /// ejecuta los efectos.
    public func handle(_ event: HUDEvent) async {
        let before = state.screen
        let (next, effects) = HUDStateMachine.reduce(state, event)
        state = next
        if next.screen != before { await rerender() }
        for effect in effects { await perform(effect) }
    }

    private func rerender() async {
        await body.render(HUDRenderer.render(state.screen))
    }

    // MARK: - Efectos

    private func perform(_ effect: HUDEffect) async {
        switch effect {
        case .startListening:
            endSpeech()
            listenTask?.cancel()
            let voice = self.voice
            listenTask = Task { [weak self] in
                let failure = GlassesBox<VoiceCaptureFailure?>(nil)
                let transcript = await voice.capture(onRoute: { route in
                    Task { @MainActor in await self?.handle(.listeningRoute(viaPhone: route == .phoneMic)) }
                }, onPartial: { _ in }, onFailure: { reason in
                    failure.value = reason
                })
                guard !Task.isCancelled else { return }
                // El fallo se entrega DESPUÉS de la captura (orden garantizado):
                // un transcript nil antes lo habría mandado al Home sin aviso.
                if let reason = failure.value {
                    await self?.handle(.voiceFailed(reason.message))
                } else {
                    await self?.handle(.transcript(transcript))
                }
            }
        case .stopListening:
            voice.cancel()
            listenTask?.cancel()
            listenTask = nil
        case .submit(let text):
            sink.yield(.voiceTranscript(text))
            turnTask?.cancel()
            turnTask = Task { [weak self] in
                await self?.runTurn(mirror: text, content: [AudioTool.transcriptBlock(text)])
            }
        case .capturePhoto:
            captureTask?.cancel()
            let body = self.body
            captureTask = Task { [weak self] in
                let event: HUDEvent
                do {
                    let data = try await body.capturePhoto(onPhase: { [weak self] phase in
                        Task { @MainActor in await self?.handle(.photoPhase(phase)) }
                    })
                    if let image = ImageDownscaler.imageBlock(from: data) {
                        event = .photoCaptured(image)
                    } else {
                        body.diagnostics.record(.photo, "imagen ilegible (\(data.count) bytes)")
                        event = .photoFailed("La foto llegó dañada. Reintenta.")
                    }
                } catch {
                    guard let message = HUDPhoto.message(for: error) else { return }
                    event = .photoFailed(message)
                }
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        case .cancelCapture:
            captureTask?.cancel()
            captureTask = nil
        case .submitPhoto(let image):
            turnTask?.cancel()
            turnTask = Task { [weak self] in
                await self?.runTurn(mirror: HUDPhoto.question, content: [.text(HUDPhoto.prompt), image])
            }
        case .returnHomeLater:
            homeTask?.cancel()
            let shown = state.screen
            let dwell = errorDwell
            homeTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
                guard !Task.isCancelled, let self, self.state.screen == shown else { return }
                await self.handle(.action(.back))
            }
        case .cancelTurn:
            turnTask?.cancel()
            turnTask = nil
        case .speak(let text):
            if var session = speechSession, session.turn == turnGeneration, !turnScript.finished {
                // Ya se dice por oración: cerrar con la última + la remisión al teléfono.
                let tail = turnScript.finish()
                session.script = turnScript
                speechSession = session
                enqueue(tail)
                session.queue.finish()
                await refreshWindow()
            } else {
                let heading: String
                if case .speaking(let card) = state.screen { heading = card.heading } else { heading = "" }
                let session = startSpeech(SpokenScript(whole: text), heading: heading, turn: nil)
                enqueue(session.script.utterances)
                session.queue.finish()
            }
        case .stopSpeaking:
            endSpeech()
        case .resolveCamera(let approved):
            resolveCamera(approved)
        case .openPhone:
            openPhone(router?.phone?.lastMirroredTurnID)
        }
    }

    // MARK: - TTS por oración + karaoke

    /// Abre una cola de TTS: las utterances se dicen en orden, una tras otra;
    /// al vaciarse la cola cerrada, `.speechFinished`.
    private func startSpeech(_ script: SpokenScript, heading: String, turn: Int?) -> SpeechSession {
        endSpeech()
        let generation = speechGeneration
        let (stream, queue) = AsyncStream<(Int, String)>.makeStream()
        let session = SpeechSession(generation: generation, turn: turn, script: script, heading: heading, queue: queue)
        speechSession = session
        pager = HUDSpokenPager(script.text, after: heading)
        let speech = self.speech
        speakTask = Task { [weak self] in
            for await (index, text) in stream {
                guard !Task.isCancelled else { return }
                await speech.speak(text) { range in
                    Task { @MainActor in await self?.spoke(index, range, generation: generation) }
                }
            }
            guard !Task.isCancelled else { return }
            await self?.speechDrained(generation)
        }
        return session
    }

    /// Encola las utterances NUEVAS (las últimas del script de la sesión).
    private func enqueue(_ utterances: [String]) {
        guard let session = speechSession, !utterances.isEmpty else { return }
        let first = session.script.utterances.count - utterances.count
        for (k, text) in utterances.enumerated() { session.queue.yield((first + k, text)) }
    }

    private func endSpeech() {
        speech.stop()
        speechSession?.queue.finish()
        speechSession = nil
        speakTask?.cancel()
        speakTask = nil
        speechGeneration += 1
    }

    private func speechDrained(_ generation: Int) async {
        guard generation == speechGeneration else { return }
        speechSession = nil
        await handle(.speechFinished)
    }

    /// Un delta del turno: las oraciones completas se encolan YA en el TTS; la
    /// primera pasa la vista de "pensando…" a speaking.
    private func streamed(_ delta: String, reply: String, turn: Int) async {
        guard turn == turnGeneration, !turnSpeechDismissed else { return }
        let fresh = turnScript.feed(delta)
        if var session = speechSession, session.turn == turn {
            session.script = turnScript
            speechSession = session
            enqueue(fresh)
            await refreshWindow()
            return
        }
        guard !fresh.isEmpty else { return }
        switch state.screen {
        case .thinking:
            let heading = HUDSummary.card(from: reply).heading
            let session = startSpeech(turnScript, heading: heading, turn: turn)
            enqueue(session.script.utterances)
            let window = pager?.window ?? ""
            await handle(.replyStarted(HUDCard(heading: heading, body: window, overflow: false)))
        case .agentCard:
            let session = startSpeech(turnScript, heading: "", turn: turn)
            enqueue(session.script.utterances)
        default:
            turnSpeechDismissed = true   // el dueño ya se movió: no hablarle encima
        }
    }

    /// El texto hablado creció: re-pagina y re-envía SOLO si la ventana visible cambió.
    private func refreshWindow() async {
        guard let session = speechSession, case .speaking(let card) = state.screen else { return }
        var fresh = HUDSpokenPager(session.script.text, after: session.heading)
        _ = fresh.advance(to: NSRange(location: session.lastLocation, length: 0))
        pager = fresh
        if fresh.window != card.body { await handle(.speechWindow(fresh.window)) }
    }

    /// Progreso del TTS (rango de la utterance `index`) → ventana del pager.
    /// Re-envía la card SOLO si cambió de ventana (histéresis: nada por palabra).
    func spoke(_ index: Int, _ range: NSRange, generation: Int) async {
        guard generation == speechGeneration, var session = speechSession else { return }
        let absolute = session.script.absolute(index, range)
        if absolute.location != NSNotFound { session.lastLocation = absolute.location }
        speechSession = session
        guard case .speaking = state.screen, var pager, let window = pager.advance(to: absolute) else { return }
        self.pager = pager
        await handle(.speechWindow(window))
    }

    /// El turno por el AgentLoop normal, marcado como superficie gafas.
    private func runTurn(mirror: String, content: [ContentBlock]) async {
        turnGeneration += 1
        let turn = turnGeneration
        turnScript = SpokenScript()
        turnSpeechDismissed = false
        await deliver(.userTurn(text: mirror, origin: .glassesHUD))
        var reply = ""
        var committed = ""
        var refused = false
        var failure: String?
        let stream = await runner.run(sessionId: sessionId, content: content, surface: .glassesHUD)
        for await event in stream {
            switch event {
            case .textDelta(let delta):
                reply += delta
                if !refused { await streamed(delta, reply: reply, turn: turn) }
            case .refused: refused = true
            case .assistantMessage: committed = reply
            case .retracted:
                // Lo retraído no se sigue diciendo: se corta el TTS y la
                // respuesta corregida se dice entera al cerrar el turno.
                reply = committed
                endSpeech()
                turnScript = SpokenScript()
                turnSpeechDismissed = true
            case .toolFailure(let notice) where !reply.hasPrefix(notice):
                reply = reply.isEmpty ? notice : notice + "\n\n" + reply
            case .error(let message): failure = message
            case .stopped(let stop): failure = "Turno detenido (\(stop))."
            default: break
            }
        }
        guard !Task.isCancelled else { return }
        if refused {
            let text = reply.isEmpty ? "Prefiero no hacer eso. Dime qué buscas y encontramos otra vía." : reply
            await deliver(.declined(text: text, origin: .glassesHUD))
        } else if let failure, reply.isEmpty {
            await deliver(.status(failure))
            await handle(.turnFailed(failure))
        } else {
            await deliver(.assistantTurn(text: reply, origin: .glassesHUD))
        }
    }

    /// Origen + espejo en el teléfono (o directo, sin router).
    private func deliver(_ content: SurfaceContent) async {
        if let router { await router.route(content) } else { await render(content) }
    }

    // MARK: - Surface

    public func render(_ content: SurfaceContent) async {
        switch content {
        case .assistantTurn(let text, .glassesHUD):
            await handle(.turnFinished(reply: text))
        case .declined(let text, .glassesHUD):
            await handle(.turnRefused(text))
        default:
            break   // el HUD no espeja turnos del teléfono (etiqueta de atención §4.3)
        }
    }

    // MARK: - Host de las tools de gafas

    public func glassesActive() async -> Bool {
        await body.currentStatus().isActive
    }

    public func project(_ card: HUDFlexBox) async -> Bool {
        guard await glassesActive() else { return false }
        await handle(.agentCard(card))
        if case .agentCard(let shown) = state.screen { return shown == card }
        return false
    }

    public func capturePOV() async throws -> Data {
        try await body.capturePhoto()
    }

    /// El `ask` de `glasses_camera`: card "¿Tomo una foto?" + pinch EN las gafas.
    /// Fail-closed: sin gafas activas, otra confirmación pendiente o timeout → no.
    public func confirmCamera(_ request: ConfirmationRequest) async -> Bool {
        guard await glassesActive(), cameraContinuation == nil else { return false }
        cameraRequestID += 1
        let requestID = cameraRequestID
        let timeout = cameraTimeout
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.cameraTimedOut(requestID)
        }
        return await withCheckedContinuation { continuation in
            cameraContinuation = continuation
            Task { await self.handle(.cameraRequested(reason: request.summary)) }
        }
    }

    private func cameraTimedOut(_ requestID: Int) async {
        guard requestID == cameraRequestID, cameraContinuation != nil else { return }
        await handle(.action(.cameraDeny))
    }

    private func resolveCamera(_ approved: Bool) {
        let continuation = cameraContinuation
        cameraContinuation = nil
        continuation?.resume(returning: approved)
    }
}
