// ChatView.swift — el chat según el handoff (§Chat, §Header, §Plasticity badge,
// §Mind sheet): mind messages sin burbuja con thought line colapsable y caret
// de streaming; user bubbles surface+border a la derecha (≤80%); error card y
// refusal card (el mensaje nunca se pierde); composer cámara · campo · mic/send;
// badge de plasticidad en el header que abre el Mind sheet.

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class ChatViewModel: ObservableObject {
    public struct DisplayMessage: Identifiable, Sendable {
        public let id = UUID()
        public var role: Message.Role
        public var text: String = ""
        public var thinking: String = ""
        public var isError: Bool = false
        public var isStreaming: Bool = false
        public var isRefusal: Bool = false
        /// Skill automatizada del turno: pasos aferentes que el runner ya corrió.
        public var automation: SkillAutomationSummary?
        // Fase 4 (§5.8): propuesta proactiva del deseo. resolved oculta las acciones.
        public var isProactive: Bool = false
        public var intentionId: String?
        public var resolved: Bool = false
        /// Cómo respondió el dueño a la propuesta (estado visible tras responder).
        public var outcome: Intention.Outcome?
        /// Capa proactiva: el recordatorio entregado o la meta del check-in.
        public var reminderId: String?
        public var goalId: String?
        /// Hora del aviso/pregunta y meta asociada: la etiqueta de la card.
        public var proactiveAt: Date?
        public var goalStatement: String?
        /// Turno del dueño dicho por voz (mic del composer o gafas): queda marcado.
        public var isVoice: Bool = false
        /// Separador sutil "— nueva sesión —" entre el historial anterior y el actual.
        public var isSessionDivider: Bool = false
        /// Foto del turno del dueño (JPEG ya reducido): thumb sobre la burbuja.
        public var imageData: Data?
        /// Solo-teléfono: la foto viajó como descripción de texto (FIX G).
        public var photoSentAsText: Bool = false
        /// Cuándo se dijo: hora al pie y separador de día (como WhatsApp).
        public var sentAt = Date()
        /// Una tool falló en el turno: el texto abre con "⚠️ No pude …" y la
        /// card lleva el ícono de alerta.
        public var toolFailure: Bool = false

        /// Tipo de card proactiva (nil si es un mensaje normal).
        public var proactiveKind: ProactiveMessage.Kind? {
            guard isProactive else { return nil }
            if let reminderId { return .reminder(id: reminderId) }
            if let goalId { return .checkIn(goalId: goalId) }
            if let intentionId { return .intention(id: intentionId) }
            return nil
        }

        static func proactive(_ item: ProactiveMessage) -> DisplayMessage {
            var message = DisplayMessage(role: .assistant, text: item.text, isProactive: true)
            switch item.kind {
            case .reminder(let id): message.reminderId = id
            case .checkIn(let goalId): message.goalId = goalId
            case .intention(let id): message.intentionId = id
            }
            message.proactiveAt = item.at
            message.goalStatement = item.goalStatement
            return message
        }
    }

    /// Reloj y formato de fechas de las cards y las horas (inyectables en tests).
    public var now: @Sendable () -> Date = { Date() }
    public var dates = AnimaDateText()

    /// "Recordatorio · hoy 8:30 p. m." | "Seguimiento · <meta>" | "Propuesta".
    public func cardLabel(_ message: DisplayMessage) -> String {
        guard let kind = message.proactiveKind else { return "" }
        return ProactiveCard.label(kind, at: message.proactiveAt, goalStatement: message.goalStatement,
                                   now: now(), dates: dates, selfName: selfName)
    }

    /// "8:30 p. m." al pie de cada mensaje.
    public func timeLabel(_ message: DisplayMessage) -> String {
        dates.time(message.sentAt)
    }

    /// Separadores de día ("Hoy", "Ayer", "lunes 5 de octubre") antes del primer
    /// mensaje de cada día; el separador de sesión no cuenta como mensaje.
    public func dayHeaders() -> [UUID: String] {
        Self.dayHeaders(messages, now: now(), dates: dates)
    }

    public static func dayHeaders(_ messages: [DisplayMessage], now: Date, dates: AnimaDateText) -> [UUID: String] {
        var out: [UUID: String] = [:]
        var lastDay: Date?
        for message in messages where !message.isSessionDivider {
            let day = dates.calendar.startOfDay(for: message.sentAt)
            if day != lastDay { out[message.id] = dates.dayHeader(message.sentAt, now: now) }
            lastDay = day
        }
        return out
    }

    public func cardFollowUp(_ message: DisplayMessage) -> String? {
        guard let kind = message.proactiveKind else { return nil }
        return ProactiveCard.followUp(kind, at: message.proactiveAt, now: now())
    }

    /// Foto elegida en el composer, esperando el texto opcional del dueño.
    public struct PendingImage: Sendable, Equatable {
        public var block: ContentBlock
        public var thumb: Data
    }

    public static let photosNeedRemoteNote = "Las fotos necesitan un modelo remoto (Claude, OpenAI o Gemini)."

    public static let sessionDividerText = "— nueva sesión —"

    /// Historial persistido → mensajes del chat. Si la sesión es nueva (ventana
    /// de 8 h), el historial de la ANTERIOR va arriba con un separador: el dueño
    /// nunca ve vacío si hubo conversación (el contexto del modelo es otro).
    public static func history(current: [VisibleTurn], previous: [VisibleTurn] = [],
                               boundaries: [ContextBoundary] = []) -> [DisplayMessage] {
        func message(_ turn: VisibleTurn) -> DisplayMessage {
            if turn.role == .assistant, let tag = turn.proactive,
               let proactive = ProactiveMessage(tag: tag, text: turn.text) {
                var card = DisplayMessage.proactive(proactive)
                if let createdAt = turn.createdAt { card.sentAt = createdAt }
                return card
            }
            var message = DisplayMessage(role: turn.role, text: turn.text, isVoice: turn.isVoice,
                                         imageData: turn.imageBase64.flatMap { Data(base64Encoded: $0) })
            message.toolFailure = turn.role == .assistant && turn.text.hasPrefix(ToolFailureNotice.marker)
            if let createdAt = turn.createdAt { message.sentAt = createdAt }
            return message
        }
        var out = previous.map(message)
        if !out.isEmpty {
            out.append(DisplayMessage(role: .assistant, text: sessionDividerText, isSessionDivider: true))
        }
        var pending = boundaries.sorted { $0.fromSeq < $1.fromSeq }
        for turn in current {
            while let next = pending.first, let seq = turn.seq, seq >= next.fromSeq {
                out.append(DisplayMessage(role: .assistant, text: next.dividerText, isSessionDivider: true))
                pending.removeFirst()
            }
            out.append(message(turn))
        }
        out += pending.map { DisplayMessage(role: .assistant, text: $0.dividerText, isSessionDivider: true) }
        return out
    }

    /// Carga el historial al cablearse (antes de cualquier turno nuevo).
    public func loadHistory(current: [VisibleTurn], previous: [VisibleTurn] = [], boundaries: [ContextBoundary] = []) {
        let restored = Self.history(current: current, previous: previous, boundaries: boundaries)
        guard !restored.isEmpty else { return }
        messages = restored + messages
    }

    /// Estado de la mente para el badge y el Mind sheet.
    public struct MindState: Sendable, Equatable {
        public var p: Double = 1.0
        public var cycles: Int = 0
        public var regime: Plasticity.Regime = .bootstrap

        public var regimeLabel: String {
            switch regime {
            case .bootstrap: return "infancia"
            case .adolescence: return "adolescencia"
            case .maturity: return "madurez"
            }
        }

        public var regimeSentence: String {
            switch regime {
            case .bootstrap:
                return "Se está formando: todo lo que viven juntos la moldea directo."
            case .adolescence:
                return "Su identidad se asienta: los cambios de fondo te preguntan primero."
            case .maturity:
                return "Madura: identidad y valores solo cambian con tu aprobación."
            }
        }
    }

    @Published public var messages: [DisplayMessage] = []
    @Published public var input: String = ""
    @Published public var isStreaming: Bool = false
    @Published public var errorText: String?
    @Published public private(set) var mind = MindState()
    /// Nombre del self para el header (FIX D): la identidad de ELLA, no la marca.
    @Published public private(set) var selfName: String = Birth.seed.name
    /// Cuánto del contexto del modelo activo ocupa la conversación (medidor).
    @Published public private(set) var contextGauge: ContextGauge?
    /// Cambios de identidad / metas inferidas esperando al dueño: aviso sobre el chat.
    @Published public var pendingApprovals = 0
    /// Tap al aviso → Ajustes → Mente (lo cablea el shell).
    public var onOpenApprovals: (() -> Void)?
    /// Deep link "ver en el teléfono": el turno al que hay que hacer scroll.
    @Published public var focusedMessageId: UUID?
    /// PhoneChatSurface: ancla del último turno espejado desde otra superficie.
    public private(set) var lastMirroredTurnID: UUID?
    public let events: AsyncStream<SurfaceEvent>
    private let eventSink: AsyncStream<SurfaceEvent>.Continuation

    private let loop: AgentLoop
    private let sessionId: SessionID
    private let desireEngine: DesireEngine?
    private let selfModel: SelfModel?
    private var shownIntentionIds: Set<String> = []
    /// Track G: el cuerpo-gafas (línea de cuerpo del header + Mind sheet). nil ⇒ solo teléfono.
    public var glasses: GlassesViewModel?
    private var lastUserContent: [ContentBlock]?
    /// Voz desde el composer (mic del TELÉFONO). nil ⇒ el mic no está disponible.
    public var voice: (any VoiceCapturePort)?
    /// Listening bar en lugar del composer + transcript en vivo.
    @Published public private(set) var isListening = false
    @Published public private(set) var liveTranscript = ""
    private var voiceCancelled = false
    /// Foto del composer (cámara o galería) pendiente de enviar.
    @Published public private(set) var pendingImage: PendingImage?
    /// Solo-teléfono (FoundationModels) no ve imágenes: el menú lo dice y no adjunta.
    public var photosAvailable = true
    /// `--uitest`: el picker es un doble que entrega una imagen fixture.
    public var injectedPhoto: (@MainActor () -> Data?)?
    /// Etiquetas on-device de una foto (Vision) para cuando el córtex no ve imágenes.
    public var describeImage: @Sendable (Data) async -> [String] = { await ImageDescriber.labels(for: $0) }

    /// Aviso honesto en el composer: hay foto adjunta y el modelo activo no la ve.
    public var pendingImageNotice: String? {
        pendingImage != nil && !photosAvailable ? ImageDescriber.notice : nil
    }

    /// Placeholder del campo: con adjunto, el hint de que falta el paso de enviar.
    public var inputPlaceholder: String { pendingImage == nil ? "Mensaje" : "Agrega un mensaje…" }

    public init(loop: AgentLoop, sessionId: SessionID, desireEngine: DesireEngine? = nil,
                selfModel: SelfModel? = nil) {
        self.loop = loop
        self.sessionId = sessionId
        self.desireEngine = desireEngine
        self.selfModel = selfModel
        (events, eventSink) = AsyncStream<SurfaceEvent>.makeStream()
    }

    /// Refresca p/ciclos/régimen para el badge (anima 600 ms al cambiar).
    public func loadMind() async {
        guard let selfModel else { return }
        let name = await selfModel.name()
        if name != selfName { selfName = name }
        let cycles = await selfModel.cycles()
        let state = MindState(p: Plasticity.value(cycles: cycles), cycles: cycles,
                              regime: Plasticity.regime(cycles: cycles))
        if state != mind {
            withAnimation(.easeInOut(duration: Theme.Motion.plasticity)) { mind = state }
        }
    }

    /// Trae las Intentions pendientes del deseo y las inserta como mensajes
    /// proactivos del agente (§5.8). Idempotente: no re-muestra una ya pintada.
    public func loadProactiveIntentions() async {
        guard let desireEngine else { return }
        let pending = await desireEngine.pendingIntentions()
        for intention in pending where !shownIntentionIds.contains(intention.id) {
            shownIntentionIds.insert(intention.id)
            messages.append(.proactive(ProactiveMessage(kind: .intention(id: intention.id), text: intention.proposedText,
                                                        at: intention.createdAt)))
        }
    }

    /// Mensajes proactivos ya persistidos (recordatorio entregado, check-in) →
    /// cards en el chat. Idempotente por recordatorio/meta pendiente.
    public func appendProactive(_ proactive: [ProactiveMessage]) {
        for item in proactive {
            switch item.kind {
            case .reminder(let id):
                guard !messages.contains(where: {
                    $0.reminderId == id && $0.text == item.text && $0.proactiveAt == item.at
                }) else { continue }
                messages.append(.proactive(item))
            case .checkIn(let goalId):
                guard !messages.contains(where: { $0.goalId == goalId && $0.text == item.text && !$0.resolved }) else { continue }
                messages.append(.proactive(item))
            case .intention(let id):
                guard !shownIntentionIds.contains(id) else { continue }
                shownIntentionIds.insert(id)
                messages.append(.proactive(item))
            }
        }
    }

    /// Deep link de una notificación proactiva: scroll al mensaje que la representa.
    public func focus(_ kind: ProactiveMessage.Kind) {
        let match = messages.last { message in
            switch kind {
            case .reminder(let id): return message.reminderId == id
            case .checkIn(let goalId): return message.goalId == goalId
            case .intention(let id): return message.intentionId == id
            }
        }
        focusedMessageId = match?.id ?? messages.last?.id
    }

    /// "Hagámoslo": la propuesta queda aceptada Y el dueño se lo dice a ella,
    /// para que la EJECUTE (cree el recordatorio, el bloque…) y responda.
    public func accept(_ message: DisplayMessage) async {
        await resolve(message, outcome: .accepted)
        let text = Self.acceptText(message.text)
        await run(DisplayMessage(role: .user, text: text), content: [.text(text)])
    }

    public static func acceptText(_ proposal: String) -> String { "Acepto: \(proposal)" }

    public func dismiss(_ message: DisplayMessage) async {
        await resolve(message, outcome: .dismissed)
    }

    private func resolve(_ message: DisplayMessage, outcome: Intention.Outcome) async {
        guard let id = message.intentionId else { return }
        await desireEngine?.recordOutcome(id: id, outcome: outcome)
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index].resolved = true
            messages[index].outcome = outcome
        }
    }

    public func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage
        guard !text.isEmpty || image != nil, !isStreaming else { return }
        input = ""
        pendingImage = nil
        if !text.isEmpty { eventSink.yield(.userText(text)) }
        var content: [ContentBlock] = []
        var asText = false
        if let image {
            if photosAvailable {
                content.append(image.block)
            } else {
                // Solo-teléfono no ve imágenes: la foto va como descripción (avisado), jamás en silencio.
                asText = true
                content.append(.text(ImageDescriber.textBlock(labels: await describeImage(image.thumb))))
            }
        }
        if !text.isEmpty { content.append(.text(text)) }
        await dispatch(DisplayMessage(role: .user, text: text, imageData: image?.thumb, photoSentAsText: asText),
                  content: content)
    }

    // MARK: Foto (cámara / galería → ImageDownscaler → thumb en el composer)

    /// Bytes crudos del picker → ≤1568px JPEG. false si no es imagen o no hay modelo que la vea.
    @discardableResult
    public func attachPhoto(_ data: Data) -> Bool {
        guard let block = ImageDownscaler.imageBlock(from: data) else { return false }
        return attach(block)
    }

    /// Image block ya reducido (CameraPicker / PhotoLibraryPicker).
    @discardableResult
    public func attach(_ block: ContentBlock) -> Bool {
        guard photosAvailable, case .image(_, let base64) = block, let thumb = Data(base64Encoded: base64) else {
            return false
        }
        pendingImage = PendingImage(block: block, thumb: thumb)
        return true
    }

    /// X del thumb: se envía solo el texto.
    public func removePhoto() {
        pendingImage = nil
    }

    // MARK: Voz (mic del composer → mismo pipeline que las gafas, ruta teléfono)

    /// Tap al mic: listening bar + transcript en vivo; fin por silencio o "Listo".
    public func startVoice() {
        guard let voice, !isListening, !isStreaming else { return }
        isListening = true
        liveTranscript = ""
        voiceCancelled = false
        Task { [weak self] in
            let transcript = await voice.capture(onRoute: { _ in }, onPartial: { partial in
                Task { @MainActor in
                    guard let self, self.isListening else { return }
                    self.liveTranscript = partial
                }
            })
            await self?.voiceEnded(transcript)
        }
    }

    /// "Listo": envía lo oído sin esperar el silencio.
    public func finishVoice() {
        guard isListening else { return }
        voice?.finish()
    }

    /// X o tap fuera: descarta sin enviar.
    public func cancelVoice() {
        guard isListening else { return }
        voiceCancelled = true
        isListening = false
        liveTranscript = ""
        voice?.cancel()
    }

    func voiceEnded(_ transcript: String?) async {
        let cancelled = voiceCancelled
        isListening = false
        liveTranscript = ""
        guard !cancelled else { return }
        let text = (transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        eventSink.yield(.voiceTranscript(text))
        await dispatch(DisplayMessage(role: .user, text: text, isVoice: true), content: [AudioTool.transcriptBlock(text)])
    }

    /// "Reintentar" del error card: reintenta el último turno sin duplicar la
    /// burbuja del usuario — el mensaje nunca se pierde. Si fue por contexto
    /// excedido, primero recorta la conversación (si no, reintentar repetía el error).
    public func retry() async {
        guard let content = lastUserContent, !isStreaming else { return }
        if messages.last?.isError == true, messages.last?.text == AgentLoop.contextExceededMessage {
            try? await loop.trimHistory(sessionId: sessionId)
            messages.append(DisplayMessage(role: .assistant, text: ContextBoundary(
                kind: .trim, fromSeq: 0, model: contextGauge?.model, createdAt: now()).dividerText,
                isSessionDivider: true))
        }
        await dispatch(nil, content: content)
    }

    // MARK: Conexión (5b #7)

    @Published public private(set) var isOffline = false
    /// La conversación va a un modelo remoto (Claude/OpenAI/Gemini): sin red, se encola.
    public var usesRemoteConversation = false
    /// Hay modelo local para seguir sin red (Solo teléfono / Híbrido).
    public var localModelAvailable = false
    private var queuedContent: [ContentBlock]?
    public static let offlineQueuedNote = "Sin conexión: te lo envío apenas vuelva la red."

    /// Turno del dueño: sin red y con modelo remoto, se muestra y se encola
    /// (con aviso claro) en vez de fallar y pedir "Reintentar".
    private func dispatch(_ bubble: DisplayMessage?, content: [ContentBlock]) async {
        guard isOffline, usesRemoteConversation else {
            await run(bubble, content: content)
            return
        }
        if let bubble { messages.append(bubble) }
        messages.append(DisplayMessage(role: .assistant, text: Self.offlineQueuedNote, isSessionDivider: true))
        lastUserContent = content
        queuedContent = content
    }

    public var hasQueuedTurn: Bool { queuedContent != nil }

    public func setOffline(_ offline: Bool) async {
        guard offline != isOffline else { return }
        isOffline = offline
        await sendQueuedIfOnline()
    }

    /// El turno encolado sin red sale apenas hay red y nada en curso (si la red
    /// volvió a mitad de un turno, sale al terminarlo).
    private func sendQueuedIfOnline() async {
        guard !isOffline, let content = queuedContent, !isStreaming else { return }
        queuedContent = nil
        await run(nil, content: content)
    }

    // MARK: Contexto (medidor, compactar, nueva conversación)

    /// Lo cablea el shell: resume la sesión con el córtex de ciclo.
    public var compactor: ConversationCompactor?
    /// Lo cablea el shell: cierra la sesión y abre una nueva (memoria intacta).
    public var onNewConversation: (() -> Void)?
    @Published public private(set) var isCompacting = false

    public func refreshContext() async {
        contextGauge = await loop.contextGauge(sessionId: sessionId)
    }

    public func compact() async {
        guard let compactor, !isStreaming, !isCompacting else { return }
        isCompacting = true
        defer { isCompacting = false }
        let outcome = (try? await compactor.compact(sessionId: sessionId)) ?? .nothingToDo
        let divider: String?
        switch outcome {
        case .compacted: divider = ContextBoundary(kind: .compaction, fromSeq: 0, createdAt: now()).dividerText
        case .trimmed: divider = ContextBoundary(kind: .trim, fromSeq: 0, model: contextGauge?.model,
                                                 createdAt: now()).dividerText
        case .nothingToDo: divider = nil
        }
        if let divider {
            messages.append(DisplayMessage(role: .assistant, text: divider, isSessionDivider: true))
        }
        await refreshContext()
    }

    public static let newConversationText = "— nueva conversación —"

    /// El chat recién abierto por "Nueva conversación": solo el separador.
    public func markNewConversation() {
        messages = [DisplayMessage(role: .assistant, text: Self.newConversationText, isSessionDivider: true)]
    }

    private func run(_ bubble: DisplayMessage?, content: [ContentBlock]) async {
        errorText = nil
        lastUserContent = content
        if let bubble {
            messages.append(bubble)
        }

        var assistant = DisplayMessage(role: .assistant, isStreaming: true)
        messages.append(assistant)
        var index = messages.count - 1
        isStreaming = true

        for await event in await loop.run(sessionId: sessionId, content: content, surface: .phoneChat) {
            switch event {
            case .textDelta(let d):
                assistant.text += d
            case .thinkingDelta(let d):
                assistant.thinking += d
            case .refused:
                assistant.isRefusal = true
                if assistant.text.isEmpty {
                    assistant.text = "Prefiero no hacer eso. Dime qué buscas y encontramos otra vía."
                }
            case .error(let message):
                assistant.isError = true
                if assistant.text.isEmpty { assistant.text = message }
            case .stopped(let stop):
                errorText = "Turno detenido: \(stop)"
            case .skillAutomated(let summary):
                assistant.automation = summary
            case .contextTrimmed(let model):
                // El separador va antes del turno que lo provocó.
                let at = bubble == nil ? index : max(0, index - 1)
                messages.insert(DisplayMessage(role: .assistant, text: ContextBoundary(
                    kind: .trim, fromSeq: 0, model: model, createdAt: now()).dividerText, isSessionDivider: true),
                    at: at)
                index += 1
            case .context(let gauge):
                contextGauge = gauge
            case .toolFailure(let notice):
                assistant.toolFailure = true
                if !assistant.text.hasPrefix(notice) {
                    let body = assistant.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    assistant.text = body.isEmpty ? notice : notice + "\n\n" + body
                }
            case .toolStarted, .toolFinished, .assistantMessage, .turnFinished:
                break
            }
            assistant.isStreaming = true
            if messages.indices.contains(index) { messages[index] = assistant }
        }

        assistant.isStreaming = false
        if messages.indices.contains(index) { messages[index] = assistant }
        isStreaming = false
        await loadMind()
        await refreshContext()
        await sendQueuedIfOnline()
    }
}

// MARK: - PhoneChatSurface (doc 05 §3.2): MISMO contrato que el HUD

extension ChatViewModel: PhoneChatSurface {
    public nonisolated var id: SurfaceID { .phoneChat }
    public nonisolated var capabilities: SurfaceCapabilities { .phoneChat }

    /// Espejo de los turnos que llegaron por otra superficie (gafas): la
    /// conversación es una sola y el teléfono la muestra completa.
    public func render(_ content: SurfaceContent) async {
        switch content {
        case .userTurn(let text, let origin) where origin != .phoneChat:
            messages.append(DisplayMessage(role: .user, text: text))
        case .assistantTurn(let text, let origin) where origin != .phoneChat:
            let message = DisplayMessage(role: .assistant, text: text)
            messages.append(message)
            lastMirroredTurnID = message.id
        case .declined(let text, let origin) where origin != .phoneChat:
            let message = DisplayMessage(role: .assistant, text: text, isRefusal: true)
            messages.append(message)
            lastMirroredTurnID = message.id
        default:
            break
        }
    }

    public func focus(turn: UUID?) {
        focusedMessageId = turn ?? messages.last?.id
    }
}

// MARK: - Vista

public struct ChatView: View {
    @ObservedObject private var model: ChatViewModel
    @State private var expandedThoughts: Set<UUID> = []
    @State private var expandedAutomations: Set<UUID> = []
    @State private var showMindSheet = false
    @State private var showContextSheet = false
    /// Alto medido del sheet de contexto (abraza su contenido con cualquier Dynamic Type).
    @State private var contextSheetHeight = ContextSheet.initialHeight
    /// ¿El dueño está al fondo del chat? (si subió a leer, no se le mueve).
    @State private var followsBottom = true
    static let followSlack: CGFloat = 80
    @State private var showPhotoMenu = false
    @State private var photoSource: PhotoSource?
    /// Visor fullscreen de una foto (thumb del composer o de una burbuja).
    @State private var viewerImage: ViewerImage?
    /// Foco del composer: el teclado se cierra al enviar, al arrastrar la
    /// lista y al tocar el área de mensajes (la tab bar vuelve a verse).
    @FocusState private var inputFocused: Bool

    public init(model: ChatViewModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            Theme.Colors.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if let error = model.errorText {
                    errorBanner(error)
                }
                if model.pendingApprovals > 0 {
                    approvalsBanner(model.pendingApprovals)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        let headers = model.dayHeaders()
                        LazyVStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
                            ForEach(model.messages) { message in
                                VStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
                                    if let header = headers[message.id] {
                                        DaySeparator(text: header)
                                    }
                                    bubble(message)
                                }
                                .id(message.id)
                            }
                        }
                        .padding(Theme.Space.screenInset)
                    }
                    // Solo el offset INICIAL al fondo: anclar siempre al fondo peleaba
                    // con el scrollTo por delta y el chat "bailaba" (5b #7).
                    .followingBottom($followsBottom, slack: Self.followSlack)
                    .scrollDismissesKeyboard(.interactively)
                    // Simultáneo: cierra el teclado SIN robarle el tap a la thought
                    // line, "Reintentar" ni las acciones de las propuestas.
                    .simultaneousGesture(TapGesture().onEnded {
                        inputFocused = false
                        model.cancelVoice()   // tap fuera de la listening bar: descarta
                    })
                    .accessibilityIdentifier("chat.messages")
                    // Auto-scroll solo si el dueño ya estaba al fondo, solo cuando
                    // cambia el ÚLTIMO mensaje y sin animación (nada de loops).
                    .onChange(of: model.messages.last?.text) { _, _ in
                        guard followsBottom, let last = model.messages.last else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                    // Un mensaje nuevo del dueño siempre baja (es su acción).
                    .onChange(of: model.messages.count) { old, new in
                        guard new > old, let last = model.messages.last,
                              followsBottom || model.messages.dropLast().last?.role == .user else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                    .onChange(of: model.focusedMessageId) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
                if model.isOffline {
                    OfflinePill(localAvailable: model.localModelAvailable)
                        .padding(.top, Theme.Space.unit * 1.5)
                }
                if model.isListening {
                    ListeningBar(transcript: model.liveTranscript,
                                 onDone: { model.finishVoice() },
                                 onCancel: { model.cancelVoice() })
                } else {
                    composer
                }
            }
        }
        .task {
            await model.loadMind()
            await model.loadProactiveIntentions()
            await model.refreshContext()
        }
        .sheet(isPresented: $showContextSheet) {
            ContextSheet(model: model)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contextSheetHeight = $0 }
                .presentationDetents([.height(contextSheetHeight)])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.Colors.surface)
        }
        .sheet(isPresented: $showMindSheet) {
            MindSheet(mind: model.mind, glasses: model.glasses)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.Colors.bg)
        }
        .confirmationDialog("Foto para Anima", isPresented: $showPhotoMenu, titleVisibility: .visible) {
            if model.photosAvailable {
                Button("Tomar foto") { pickPhoto(.camera) }
                Button("Elegir de la galería") { pickPhoto(.library) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            if !model.photosAvailable { Text(ChatViewModel.photosNeedRemoteNote) }
        }
        #if os(iOS)
        .sheet(item: $photoSource) { source in
            Group {
                switch source {
                case .camera: CameraPicker { model.attach($0) }
                case .library: PhotoLibraryPicker { model.attach($0) }
                }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $viewerImage) { image in
            ImageViewer(data: image.data) { viewerImage = nil }
        }
        #else
        .sheet(item: $viewerImage) { image in
            ImageViewer(data: image.data) { viewerImage = nil }
        }
        #endif
    }

    // MARK: Header — nombre del self + body line a la izquierda, la marca
    // respirando al centro, badge de plasticidad a la derecha.

    static let headerMarkSize: CGFloat = 30

    private var header: some View {
        VStack(spacing: Theme.Space.unit * 2) {
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.Space.unit) {
                    Text(model.selfName)
                        .font(Theme.Type_.screenTitle)
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("chat.selfName")
                    BodyLine(glasses: model.glasses)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                BreathMark(size: Self.headerMarkSize, p: model.mind.p, phase: .breathing)
                    .frame(width: Self.headerMarkSize + Theme.Space.stack * 2)
                    .accessibilityHidden(true)
                Button {
                    showMindSheet = true
                    Task { await model.loadMind() }
                } label: {
                    PlasticityBadge(mind: model.mind)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("chat.plasticityBadge")
            }
            ContextMeter(gauge: model.contextGauge) { showContextSheet = true }
        }
        .padding(.horizontal, Theme.Space.screenInset)
        .padding(.top, Theme.Space.stack)
    }

    // MARK: Mensajes

    @ViewBuilder
    private func bubble(_ message: ChatViewModel.DisplayMessage) -> some View {
        if message.isSessionDivider {
            Text(message.text)
                .font(Theme.Type_.meta)
                .foregroundStyle(Theme.Colors.textFaint)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("chat.sessionDivider")
        } else {
            switch message.role {
            case .user:
                userBubble(message)
            default:
                mindMessage(message)
            }
        }
    }

    /// User bubble: surface fill + border, radius 8, derecha ≤80%.
    private func userBubble(_ message: ChatViewModel.DisplayMessage) -> some View {
        HStack {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                if let data = message.imageData {
                    Button { viewerImage = ViewerImage(data: data) } label: {
                        PhotoThumb(data: data, width: 160, height: 110)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ver foto")
                    .accessibilityIdentifier("chat.userMessage.photo")
                    if message.photoSentAsText {
                        Text("enviada como descripción")
                            .font(Theme.Type_.meta)
                            .foregroundStyle(Theme.Colors.textFaint)
                            .accessibilityIdentifier("chat.userMessage.photoAsText")
                    }
                }
                if message.isVoice {
                    Label("voz", systemImage: "waveform")
                        .font(Theme.Type_.meta)
                        .foregroundStyle(Theme.Colors.textFaint)
                        .accessibilityIdentifier("chat.userMessage.voice")
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(Theme.Type_.body)
                        .foregroundStyle(Theme.Colors.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("chat.userMessage")
                }
                MessageTime(text: model.timeLabel(message))
            }
                .padding(Theme.Space.cardPad)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .fill(Theme.Colors.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                .containerRelativeFrame(.horizontal, count: 5, span: 4, spacing: 0,
                                        alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Mind message: SIN burbuja. Orden: thought line → texto (+caret) →
    /// (error | refusal card). Las propuestas proactivas llevan borde accent.
    @ViewBuilder
    private func mindMessage(_ message: ChatViewModel.DisplayMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.isProactive {
                proactiveCard(message)
            } else {
                if let automation = message.automation {
                    automationLine(message.id, automation)
                }
                if !message.thinking.isEmpty || (message.isStreaming && message.text.isEmpty) {
                    thoughtLine(message)
                }
                if !message.text.isEmpty {
                    if message.isRefusal {
                        refusalCard(message)
                    } else if message.isError {
                        errorCard(message)
                    } else if message.toolFailure {
                        toolFailureCard(message)
                    } else {
                        streamedText(message)
                    }
                }
                if !message.isStreaming, !message.text.isEmpty {
                    MessageTime(text: model.timeLabel(message))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Una tool falló en el turno: ícono de alerta + el texto (la línea
    /// "⚠️ No pude …" sin el emoji, que ya es el ícono).
    private func toolFailureCard(_ message: ChatViewModel.DisplayMessage) -> some View {
        var shown = message
        if shown.text.hasPrefix("⚠️ ") { shown.text = String(shown.text.dropFirst("⚠️ ".count)) }
        return HStack(alignment: .top, spacing: Theme.Space.stack) {
            Image(systemName: "exclamationmark.triangle")
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.accent)
                .accessibilityLabel("No se pudo")
            streamedText(shown)
        }
        .padding(Theme.Space.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
    }

    private func streamedText(_ message: ChatViewModel.DisplayMessage) -> some View {
        HStack(alignment: .bottom, spacing: 4) {
            MarkdownMessage(text: message.text)
            if message.isStreaming {
                StreamCaret()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.assistantMessage")
        .accessibilityValue(message.isStreaming ? "streaming" : "done")
    }

    /// Thought line: la marca respirando + "Pensando…" mientras razona (sin
    /// caret: el caret solo existe con texto fluyendo), luego chevron + "Pensó ·
    /// primera frase"; tap expande el bloque con regla izquierda.
    @ViewBuilder
    private func thoughtLine(_ message: ChatViewModel.DisplayMessage) -> some View {
        let expanded = expandedThoughts.contains(message.id)
        let thinkingNow = message.isStreaming && message.text.isEmpty
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if expanded { expandedThoughts.remove(message.id) }
                else { expandedThoughts.insert(message.id) }
            } label: {
                HStack(spacing: 6) {
                    if thinkingNow {
                        ThinkingIndicator(p: model.mind.p)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(Theme.Type_.label.weight(.light))
                            .foregroundStyle(Theme.Colors.textFaint)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .animation(.easeOut(duration: 0.2), value: expanded)
                        Text("Pensó · \(firstSentence(of: message.thinking))")
                            .font(Theme.Type_.secondary)
                            .foregroundStyle(Theme.Colors.textMuted)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            if expanded, !message.thinking.isEmpty {
                Text(message.thinking)
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.textMuted)
                    .padding(.leading, Theme.Space.cardPad)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Theme.Colors.border)
                            .frame(width: 1)
                    }
            }
        }
    }

    /// Línea de skill automatizada: mismo patrón que la thought line —
    /// "⚡ <skill> ejecutó N pasos", tap expande los pasos con su resultado.
    /// Accent en línea y glow, jamás fill.
    @ViewBuilder
    private func automationLine(_ id: UUID, _ automation: SkillAutomationSummary) -> some View {
        let expanded = expandedAutomations.contains(id)
        let count = automation.steps.count
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if expanded { expandedAutomations.remove(id) } else { expandedAutomations.insert(id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(Theme.Colors.textFaint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(.easeOut(duration: 0.2), value: expanded)
                    Image(systemName: "bolt")
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(Theme.Colors.accent)
                        .shadow(color: Theme.Colors.accent.opacity(0.6), radius: 3)
                    Text("\(automation.skillName) ejecutó \(count) \(count == 1 ? "paso" : "pasos")")
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.accentText)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.skillAutomation")
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(automation.steps.enumerated()), id: \.offset) { _, step in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.step)
                                .font(Theme.Type_.meta)
                                .foregroundStyle(Theme.Colors.textMuted)
                            Text(step.isError ? "sin resultado" : step.result)
                                .font(Theme.Type_.secondary)
                                .foregroundStyle(step.isError ? Theme.Colors.textFaint : Theme.Colors.text)
                                .lineLimit(4)
                        }
                    }
                    ForEach(automation.pending, id: \.self) { pending in
                        Text("Pendiente de tu ok: \(pending)")
                            .font(Theme.Type_.meta)
                            .foregroundStyle(Theme.Colors.textFaint)
                    }
                }
                .padding(.leading, Theme.Space.cardPad)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.Colors.accent)
                        .frame(width: 1)
                        .shadow(color: Theme.Colors.accent.opacity(0.6), radius: 3)
                }
            }
        }
    }

    private func firstSentence(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = trimmed.firstIndex(where: { $0 == "." || $0 == "\n" }) {
            return String(trimmed[..<end])
        }
        return trimmed
    }

    /// Error card: borde, label, body y "Reintentar" — el mensaje nunca se pierde.
    private func errorCard(_ message: ChatViewModel.DisplayMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NO SE ALCANZÓ EL MODELO")
                .font(Theme.Type_.label)
                .kerning(0.66)
                .foregroundStyle(Theme.Colors.textMuted)
            Text(message.text)
                .font(Theme.Type_.secondary)
                .foregroundStyle(Theme.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Reintentar") { Task { await model.retry() } }
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Colors.accentText)
                    .frame(minHeight: Theme.minHitTarget)
                    .disabled(model.isStreaming)
            }
        }
        .padding(Theme.Space.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
    }

    /// Refusal card: borde, label "Rechazado", body 15pt en color de texto pleno.
    /// El rechazo se dice claro y con alternativa.
    private func refusalCard(_ message: ChatViewModel.DisplayMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECHAZADO")
                .font(Theme.Type_.label)
                .kerning(0.66)
                .foregroundStyle(Theme.Colors.textMuted)
            Text(message.text)
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
    }

    /// Lo que ella dice sin que se lo pidan (recordatorio, check-in, propuesta):
    /// ícono accent a la izquierda, etiqueta pequeña, su voz y —si el aviso ya
    /// pasó— el seguimiento. Surface + hairline accent.
    @ViewBuilder
    private func proactiveCard(_ message: ChatViewModel.DisplayMessage) -> some View {
        let kind = message.proactiveKind
        HStack(alignment: .top, spacing: Theme.Space.stack) {
            Image(systemName: kind.map(ProactiveCard.symbol) ?? "sparkles")
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.accent)
                .shadow(color: Theme.Colors.accent.opacity(0.6), radius: 4)
                .frame(width: 22, height: 22)
                .padding(.top, Theme.Space.unit / 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.unit) {
                Text(model.cardLabel(message))
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.accentText)
                    .lineLimit(2)
                    .accessibilityIdentifier("chat.proactive.label")
                Text(message.text)
                    .font(Theme.Type_.body)
                    .foregroundStyle(Theme.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let followUp = model.cardFollowUp(message) {
                    Text(followUp)
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.textMuted)
                        .accessibilityIdentifier("chat.proactive.followUp")
                }
                if message.intentionId != nil {
                    if let outcome = message.outcome {
                        Label(outcome == .accepted ? "Aceptada" : "Descartada",
                              systemImage: outcome == .accepted ? "checkmark" : "xmark")
                            .font(Theme.Type_.meta)
                            .foregroundStyle(Theme.Colors.textFaint)
                            .accessibilityIdentifier("chat.proactive.outcome")
                    } else if !message.resolved {
                        HStack(spacing: Theme.Space.unit * 2) {
                            Button { Task { await model.accept(message) } } label: {
                                Text("Hagámoslo")
                                    .foregroundStyle(Theme.Colors.accentText)
                                    .frame(maxWidth: .infinity, minHeight: Theme.minHitTarget)
                                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                                        .strokeBorder(Theme.Colors.accent, lineWidth: Theme.Stroke.hairline))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isStreaming)
                            .accessibilityIdentifier("chat.proactive.accept")
                            Button { Task { await model.dismiss(message) } } label: {
                                Text("Ahora no")
                                    .foregroundStyle(Theme.Colors.textMuted)
                                    .frame(maxWidth: .infinity, minHeight: Theme.minHitTarget)
                                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                                        .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("chat.proactive.dismiss")
                        }
                        .font(Theme.Type_.secondary)
                        .padding(.top, Theme.Space.unit * 1.5)
                    }
                }
            }
        }
        .padding(Theme.Space.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Colors.surface))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.Colors.accent, lineWidth: Theme.Stroke.hairline))
        .opacity(message.outcome == .dismissed ? 0.55 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.proactive.\(kind?.slug ?? "intention")")
    }

    /// Aviso discreto: hay cambios esperando su aprobación (→ Ajustes → Mente).
    private func approvalsBanner(_ count: Int) -> some View {
        Button { model.onOpenApprovals?() } label: {
            HStack(spacing: Theme.Space.unit * 2) {
                Image(systemName: "checkmark.seal")
                    .font(Theme.Type_.secondary.weight(.light))
                    .foregroundStyle(Theme.Colors.accent)
                Text(ApprovalsInboxViewModel.bannerText(count))
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.accentText)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Theme.Type_.label.weight(.light))
                    .foregroundStyle(Theme.Colors.textFaint)
            }
            .padding(.horizontal, Theme.Space.cardPad)
            .frame(minHeight: Theme.minHitTarget)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(Theme.Colors.accent.opacity(0.5), lineWidth: Theme.Stroke.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Space.screenInset)
        .padding(.top, Theme.Space.unit * 2)
        .accessibilityIdentifier("chat.approvalsBanner")
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(Theme.Type_.meta)
            .foregroundStyle(Theme.Colors.accentText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.cardPad)
            .background(Theme.Colors.tint)
    }

    // MARK: Composer — cámara (40×40) · campo (surface h40) · mic/send

    private var hasDraft: Bool {
        !model.input.trimmingCharacters(in: .whitespaces).isEmpty || model.pendingImage != nil
    }

    enum PhotoSource: String, Identifiable {
        case camera, library
        var id: String { rawValue }
    }

    private func pickPhoto(_ source: PhotoSource) {
        if let injected = model.injectedPhoto {
            if let data = injected() { model.attachPhoto(data) }
        } else {
            photoSource = source
        }
    }

    /// Adjunto PENDIENTE dentro del contenedor del composer, encima del campo
    /// (como Mensajes): thumb con anillo accent, X arriba a la derecha y un check
    /// abajo que dice "listo para enviar" sin texto. Jamás flota en el historial.
    @ViewBuilder
    private var pendingAttachment: some View {
        if let image = model.pendingImage {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Button { viewerImage = ViewerImage(data: image.thumb) } label: {
                        PhotoThumb(data: image.thumb, width: 72, height: 72, ring: Theme.Colors.accent,
                                   ringWidth: Theme.Stroke.icon)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ver foto adjunta")
                    .accessibilityIdentifier("chat.attachment.thumb")
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(Theme.Type_.body)
                            .foregroundStyle(Theme.Colors.accent)
                            .background(Circle().fill(Theme.Colors.surface).padding(1))
                            .offset(x: 5, y: 5)
                            .accessibilityHidden(true)
                    }
                    Button { model.removePhoto() } label: {
                        Image(systemName: "xmark")
                            .font(Theme.Type_.tab.weight(.semibold))
                            .foregroundStyle(Theme.Colors.bg)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Theme.Colors.textMuted))
                            .overlay(Circle().strokeBorder(Theme.Colors.surface, lineWidth: Theme.Stroke.icon))
                            .frame(width: Theme.minHitTarget, height: Theme.minHitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 18, y: -18)
                    .accessibilityLabel("Quitar foto")
                    .accessibilityIdentifier("nav.close.attachment")
                }
                .padding(.top, Theme.Space.unit)
                .padding(.trailing, Theme.Space.unit * 2)
                if let notice = model.pendingImageNotice {
                    Text(notice)
                        .font(Theme.Type_.meta)
                        .foregroundStyle(Theme.Colors.accentText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chat.attachment.notice")
                }
            }
            .padding(.horizontal, Theme.Space.cardPad)
            .padding(.top, 10)
            .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.attachment.pending")
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.stack) {
            Button {
                inputFocused = false
                showPhotoMenu = true
            } label: {
                Image(systemName: "camera")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(Theme.Colors.textMuted)
                    .frame(width: 40, height: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.camera")

            // Contenedor único que crece: adjunto (si hay) + campo.
            VStack(alignment: .leading, spacing: 0) {
                pendingAttachment
                TextField(model.inputPlaceholder, text: $model.input, axis: .vertical)
                    .font(Theme.Type_.body)
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1...4)
                    .padding(.horizontal, Theme.Space.cardPad)
                    .padding(.vertical, 10)
                    .frame(minHeight: 40)
                    .focused($inputFocused)
                    .onSubmit { inputFocused = false; Task { await model.send() } }
                    .accessibilityIdentifier("chat.input")
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(Theme.Colors.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(model.pendingImage == nil ? Theme.Colors.border : Theme.Colors.accent,
                                  lineWidth: Theme.Stroke.hairline))
            .animation(.easeOut(duration: 0.2), value: model.pendingImage != nil)

            Button {
                inputFocused = false
                if hasDraft {
                    Task { await model.send() }
                } else {
                    model.startVoice()
                }
            } label: {
                Image(systemName: hasDraft ? "arrow.up" : "mic")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(width: 40, height: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .strokeBorder(Theme.Colors.accent, lineWidth: Theme.Stroke.hairline))
            }
            .buttonStyle(.plain)
            .disabled(model.isStreaming || (!hasDraft && model.voice == nil))
            .accessibilityLabel(hasDraft ? "Enviar" : "Hablar")
            .accessibilityIdentifier(hasDraft ? "chat.send" : "chat.mic")
        }
        .padding(Theme.Space.screenInset)
        // Unidad anclada abajo: el historial scrollea por detrás, separado por la regla.
        .background(Theme.Colors.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Colors.border.opacity(model.pendingImage == nil ? 0 : 1))
                .frame(height: Theme.Stroke.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.composer")
    }
}

extension View {
    /// Ancla inicial al fondo + si el usuario sigue al fondo.
    func followingBottom(_ atBottom: Binding<Bool>, slack: CGFloat) -> some View {
        defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - slack
            } action: { _, value in
                atBottom.wrappedValue = value
            }
    }
}

/// "Sin conexión" centrado sobre el composer (5b #7).
struct OfflinePill: View {
    let localAvailable: Bool

    var body: some View {
        HStack(spacing: Theme.Space.unit * 1.5) {
            Image(systemName: "wifi.slash")
                .font(Theme.Type_.label.weight(.light))
            Text(localAvailable ? "Sin conexión · modelo local disponible" : "Sin conexión")
        }
        .font(Theme.Type_.meta)
        .foregroundStyle(Theme.Colors.textMuted)
        .padding(.horizontal, Theme.Space.stack)
        .padding(.vertical, Theme.Space.unit * 1.5)
        .background(Capsule().fill(Theme.Colors.surface))
        .overlay(Capsule().strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.offline")
    }
}

/// Separador de día centrado (como WhatsApp): "Hoy", "Ayer", "lunes 5 de octubre".
struct DaySeparator: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Type_.meta)
            .foregroundStyle(Theme.Colors.textMuted)
            .padding(.horizontal, Theme.Space.unit * 2.5)
            .padding(.vertical, Theme.Space.unit)
            .overlay(Capsule().strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("chat.dayHeader")
    }
}

/// Hora pequeña y muted al pie de un mensaje.
struct MessageTime: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Type_.tabular(Theme.Type_.label))
            .foregroundStyle(Theme.Colors.textFaint)
            .accessibilityIdentifier("chat.messageTime")
    }
}

/// Foto a mostrar en el visor (thumb del composer o de una burbuja).
struct ViewerImage: Identifiable {
    let id = UUID()
    let data: Data
}

// MARK: - Línea de cuerpo (header): "solo teléfono" | "gafas conectadas"…

struct BodyLine: View {
    let glasses: GlassesViewModel?

    var body: some View {
        if let glasses {
            ObservedBodyLine(model: glasses)
        } else {
            BodyLineLabel(text: "solo teléfono", active: false)
        }
    }
}

private struct ObservedBodyLine: View {
    @ObservedObject var model: GlassesViewModel
    var body: some View { BodyLineLabel(text: model.bodyLabel, active: model.status.isActive) }
}

private struct BodyLineLabel: View {
    let text: String
    let active: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.Colors.accent)
                .frame(width: 6, height: 6)
                .shadow(color: Theme.Colors.accent.opacity(active ? 0.8 : 0), radius: 3)
            Text(text)
                .font(Theme.Type_.label)
                .kerning(0.66)
                .foregroundStyle(Theme.Colors.textFaint)
        }
        .accessibilityIdentifier("chat.bodyLine")
    }
}

/// Acción del Mind sheet: "Vincular gafas" | "Mostrar en las gafas" + "Desconectar gafas".
struct MindGlassesAction: View {
    @ObservedObject var model: GlassesViewModel

    var body: some View {
        HStack(spacing: Theme.Space.sectionGap) {
            if model.isRegistered {
                Button("Mostrar en las gafas") { model.showOnGlasses() }
                    .foregroundStyle(Theme.Colors.accentText)
                Button("Desconectar gafas") { model.unpair() }
                    .foregroundStyle(Theme.Colors.textFaint)
            } else {
                Button("Vincular gafas") { model.pair() }
                    .foregroundStyle(Theme.Colors.accentText)
            }
        }
        .font(Theme.Type_.secondary)
        .frame(minHeight: Theme.minHitTarget)
        .accessibilityIdentifier("mind.glasses")
    }
}

// MARK: - "Pensando…" con la marca

/// Indicador de carga de la marca: BreathMark pequeño respirando + "Pensando…"
/// muted. Nada de ProgressView genérico ni caret.
struct ThinkingIndicator: View {
    static let markSize: CGFloat = 17
    var p: Double = 1

    var body: some View {
        HStack(spacing: Theme.Space.unit * 1.5) {
            BreathMark(size: Self.markSize, p: p, phase: .breathing)
                .accessibilityHidden(true)
            Text("Pensando…")
                .font(Theme.Type_.secondary)
                .foregroundStyle(Theme.Colors.textMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.thinking")
    }
}

// MARK: - Plasticity badge (44×2 + `p 0.42 · adolescencia`)

public struct PlasticityBadge: View {
    let mind: ChatViewModel.MindState

    public var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Colors.border)
                Capsule().fill(Theme.Colors.accent)
                    .frame(width: 44 * mind.p)
            }
            .frame(width: 44, height: 2)
            Text("p \(String(format: "%.2f", mind.p)) · \(mind.regimeLabel)")
                .font(Theme.Type_.tabular(Theme.Type_.label))
                .foregroundStyle(Theme.Colors.accentText)
        }
        .frame(minHeight: Theme.minHitTarget, alignment: .center)
    }
}

// MARK: - Mind sheet (bottom sheet .medium)

public struct MindSheet: View {
    let mind: ChatViewModel.MindState
    let glasses: GlassesViewModel?
    @Environment(\.dismiss) private var dismiss

    public init(mind: ChatViewModel.MindState, glasses: GlassesViewModel? = nil) {
        self.mind = mind
        self.glasses = glasses
    }

    public var body: some View {
        ZStack {
            Theme.Colors.bg.ignoresSafeArea()
            VStack(spacing: Theme.Space.stack) {
                BreathMark(size: 104, p: mind.p, phase: .breathing)
                    .accessibilityElement()
                    .accessibilityLabel("marca de la mente")
                    .accessibilityIdentifier("mind.mark")
                Text("p \(String(format: "%.2f", mind.p))")
                    .font(Theme.Type_.tabular(Theme.Type_.cardTitle))
                    .foregroundStyle(Theme.Colors.accentText)
                Text(mind.cycles == 1 ? "1 noche de consolidación"
                                      : "\(mind.cycles) noches de consolidación")
                    .font(Theme.Type_.cardTitle)
                    .foregroundStyle(Theme.Colors.text)
                Text(mind.regimeSentence)
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.textMuted)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.screenInset)
                    .accessibilityIdentifier("mind.regimeSentence")
                Text("p(n) = 0.05 + 0.95·e^(−n/30)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.Colors.textFaint)

                VStack(spacing: 0) {
                    keyValueRow("cuerpo", glasses?.bodyLabel ?? "solo teléfono", id: "body")
                    Divider().background(Theme.Colors.border)
                    keyValueRow("régimen", mind.regimeLabel, id: "regime")
                    Divider().background(Theme.Colors.border)
                    keyValueRow("ciclos vividos", "\(mind.cycles)", id: "cycles")
                }
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                .padding(.horizontal, Theme.Space.screenInset)

                if let glasses {
                    MindGlassesAction(model: glasses)
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, Theme.Space.sectionGap)
        }
        .overlay(alignment: .topTrailing) { NavCloseButton("mind") { dismiss() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mind.sheet")
    }

    private func keyValueRow(_ key: String, _ value: String, id: String) -> some View {
        HStack {
            Text(key)
                .font(Theme.Type_.secondary)
                .foregroundStyle(Theme.Colors.textFaint)
            Spacer()
            Text(value)
                .font(Theme.Type_.tabular(Theme.Type_.secondary))
                .foregroundStyle(Theme.Colors.textMuted)
        }
        .frame(height: 40)
        .padding(.horizontal, Theme.Space.cardPad)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mind.row.\(id)")
    }
}

/// Listening bar (components.md): borde accent, 5 barras de onda escalonadas,
/// "Escuchando…" + transcript en vivo, acción de texto "Listo" y X para descartar.
struct ListeningBar: View {
    let transcript: String
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.stack) {
            NavCloseButton("listening", action: onCancel)
            VoiceWave()
            VStack(alignment: .leading, spacing: 2) {
                Text("Escuchando…")
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.accentText)
                    .accessibilityIdentifier("chat.listening.label")
                if !transcript.isEmpty {
                    Text(transcript)
                        .font(Theme.Type_.body)
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(3)
                        .accessibilityIdentifier("chat.listening.transcript")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Inset del texto = el del glyph de la X (unit + ~cardPad): simétrico.
            Button("Listo", action: onDone)
                .font(Theme.Type_.secondary)
                .foregroundStyle(Theme.Colors.accentText)
                .padding(.trailing, Theme.Space.cardPad)
                .frame(minHeight: Theme.minHitTarget)
                .contentShape(Rectangle())
                .accessibilityIdentifier("chat.voice.done")
        }
        .padding(.horizontal, Theme.Space.unit)
        .padding(.vertical, 6)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .strokeBorder(Theme.Colors.accent, lineWidth: Theme.Stroke.hairline))
        .padding(Theme.Space.screenInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.listeningBar")
    }
}

/// 5 barras de onda escalonadas (Theme.Motion.voiceWave, stagger 0.15).
struct VoiceWave: View {
    @State private var up = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(Theme.Colors.accent)
                    .frame(width: 3, height: up ? 18 : 6)
                    .animation(.easeInOut(duration: Theme.Motion.voiceWave)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * Theme.Motion.voiceWaveStagger), value: up)
            }
        }
        .frame(height: 20)
        .onAppear { up = true }
        .accessibilityHidden(true)
    }
}

/// Miniatura de una foto (radius 8, recorte .fill). Decode ASYNC y reducido
/// (ImageLoader, FIX G): jamás UIImage(data:) síncrono en el body; spinner
/// sutil mientras carga.
struct PhotoThumb: View {
    let data: Data
    let width: CGFloat
    let height: CGFloat
    var ring: Color = Theme.Colors.border
    var ringWidth: CGFloat = Theme.Stroke.hairline
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Theme.Colors.surface
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else if !failed {
                ProgressView().controlSize(.small).tint(Theme.Colors.accent)
                    .accessibilityIdentifier("photo.loading")
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(ring, lineWidth: ringWidth))
        .task(id: data) {
            image = await ImageLoader.load(data, maxPixel: ImageLoader.thumbMaxPixel)
            failed = image == nil
        }
    }
}
#endif
