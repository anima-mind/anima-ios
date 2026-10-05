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
        /// Turno del dueño dicho por voz (mic del composer o gafas): queda marcado.
        public var isVoice: Bool = false
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
            messages.append(DisplayMessage(role: .assistant, text: intention.proposedText,
                                           isProactive: true, intentionId: intention.id))
        }
    }

    public func accept(_ message: DisplayMessage) async {
        await resolve(message, outcome: .accepted)
    }

    public func dismiss(_ message: DisplayMessage) async {
        await resolve(message, outcome: .dismissed)
    }

    private func resolve(_ message: DisplayMessage, outcome: Intention.Outcome) async {
        guard let id = message.intentionId else { return }
        await desireEngine?.recordOutcome(id: id, outcome: outcome)
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index].resolved = true
        }
    }

    public func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        input = ""
        eventSink.yield(.userText(text))
        await run(DisplayMessage(role: .user, text: text), content: [.text(text)])
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
        await run(DisplayMessage(role: .user, text: text, isVoice: true), content: [AudioTool.transcriptBlock(text)])
    }

    /// "Try again" del error card: reintenta el último turno sin duplicar la
    /// burbuja del usuario — el mensaje nunca se pierde.
    public func retry() async {
        guard let content = lastUserContent, !isStreaming else { return }
        await run(nil, content: content)
    }

    private func run(_ bubble: DisplayMessage?, content: [ContentBlock]) async {
        errorText = nil
        lastUserContent = content
        if let bubble {
            messages.append(bubble)
        }

        var assistant = DisplayMessage(role: .assistant, isStreaming: true)
        messages.append(assistant)
        let index = messages.count - 1
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
    @State private var captureNotice: String?
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
                            ForEach(model.messages) { message in
                                bubble(message).id(message.id)
                            }
                        }
                        .padding(Theme.Space.screenInset)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    // Simultáneo: cierra el teclado SIN robarle el tap a la thought
                    // line, "Reintentar" ni las acciones de las propuestas.
                    .simultaneousGesture(TapGesture().onEnded {
                        inputFocused = false
                        model.cancelVoice()   // tap fuera de la listening bar: descarta
                    })
                    .accessibilityIdentifier("chat.messages")
                    .onChange(of: model.messages.last?.text) { _, _ in
                        if let last = model.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: model.focusedMessageId) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
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
        }
        .sheet(isPresented: $showMindSheet) {
            MindSheet(mind: model.mind, glasses: model.glasses)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.Colors.bg)
        }
        .alert("Disponible pronto", isPresented: Binding(
            get: { captureNotice != nil },
            set: { if !$0 { captureNotice = nil } }
        )) {
            Button("Entendido", role: .cancel) {}
        } message: {
            Text(captureNotice ?? "")
        }
    }

    // MARK: Header (body line + título + badge + regla que se desvanece)

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            BodyLine(glasses: model.glasses)
            HStack(alignment: .firstTextBaseline) {
                Text("Anima")
                    .font(Theme.Type_.screenTitle)
                    .foregroundStyle(Theme.Colors.text)
                Spacer()
                Button {
                    showMindSheet = true
                } label: {
                    PlasticityBadge(mind: model.mind)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.plasticityBadge")
            }
            LinearGradient(colors: [Theme.Colors.border, Theme.Colors.border.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: Theme.Stroke.hairline)
        }
        .padding(.horizontal, Theme.Space.screenInset)
        .padding(.top, Theme.Space.stack)
    }

    // MARK: Mensajes

    @ViewBuilder
    private func bubble(_ message: ChatViewModel.DisplayMessage) -> some View {
        switch message.role {
        case .user:
            userBubble(message)
        default:
            mindMessage(message)
        }
    }

    /// User bubble: surface fill + border, radius 8, derecha ≤80%.
    private func userBubble(_ message: ChatViewModel.DisplayMessage) -> some View {
        HStack {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                if message.isVoice {
                    Label("voz", systemImage: "waveform")
                        .font(Theme.Type_.meta)
                        .foregroundStyle(Theme.Colors.textFaint)
                        .accessibilityIdentifier("chat.userMessage.voice")
                }
                Text(message.text)
                    .font(Theme.Type_.body)
                    .foregroundStyle(Theme.Colors.text)
                    .accessibilityIdentifier("chat.userMessage")
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
                if !message.text.isEmpty || message.isStreaming {
                    if message.isRefusal {
                        refusalCard(message)
                    } else if message.isError {
                        errorCard(message)
                    } else {
                        streamedText(message)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Thought line: chevron que rota + "Pensando…" pulsante mientras razona,
    /// luego "Pensó · primera frase"; tap expande el bloque con regla izquierda.
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
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(Theme.Colors.textFaint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(.easeOut(duration: 0.2), value: expanded)
                    if thinkingNow {
                        ThinkingPulseLabel()
                    } else {
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

    /// Propuesta proactiva del deseo (§5.8): card con borde+glow accent.
    private func proactiveCard(_ message: ChatViewModel.DisplayMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROPUESTA DE ANIMA")
                .font(Theme.Type_.label)
                .kerning(0.66)
                .foregroundStyle(Theme.Colors.accentText)
            Text(message.text)
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.text)
                .fixedSize(horizontal: false, vertical: true)
            if !message.resolved {
                HStack(spacing: Theme.Space.stack) {
                    Button("Descartar") { Task { await model.dismiss(message) } }
                        .foregroundStyle(Theme.Colors.textMuted)
                    Spacer()
                    Button("Aceptar") { Task { await model.accept(message) } }
                        .foregroundStyle(Theme.Colors.accentText)
                }
                .font(Theme.Type_.secondary)
            }
        }
        .padding(Theme.Space.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.Colors.accent, lineWidth: Theme.Stroke.hairline))
        .shadow(color: Theme.Colors.accent.opacity(0.35), radius: 10)
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
        !model.input.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var composer: some View {
        HStack(spacing: Theme.Space.stack) {
            Button {
                captureNotice = "La cámara de Anima llega pronto; por ahora escríbele."
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

            TextField("Mensaje", text: $model.input, axis: .vertical)
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.text)
                .lineLimit(1...4)
                .padding(.horizontal, Theme.Space.cardPad)
                .padding(.vertical, 10)
                .frame(minHeight: 40)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Colors.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                .focused($inputFocused)
                .onSubmit { inputFocused = false; Task { await model.send() } }
                .accessibilityIdentifier("chat.input")

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
    }
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

// MARK: - "Pensando…" con pulso

struct ThinkingPulseLabel: View {
    @State private var dim = false

    var body: some View {
        Text("Pensando…")
            .font(Theme.Type_.secondary)
            .foregroundStyle(Theme.Colors.textMuted)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: Theme.Motion.thinkingPulse)
                    .repeatForever(autoreverses: true)) { dim = true }
            }
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
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.screenInset)
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

/// El texto del asistente con markdown: prosa inline + bloques de código en
/// vista monoespaciada sobre surface (accent jamás de relleno). Re-parsea el
/// mensaje completo en cada delta (ChatMarkdown): sin parpadeos por fragmento.
struct MarkdownMessage: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ChatMarkdown.segments(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let attributed):
                    Text(attributed)
                        .font(Theme.Type_.body)
                        .foregroundStyle(Theme.Colors.text)
                        .tint(Theme.Colors.accentText)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let code, _):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.Colors.text)
                            .textSelection(.enabled)
                            .padding(Theme.Space.cardPad)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .fill(Theme.Colors.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                }
            }
        }
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
                if !transcript.isEmpty {
                    Text(transcript)
                        .font(Theme.Type_.body)
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(3)
                        .accessibilityIdentifier("chat.listening.transcript")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Listo", action: onDone)
                .font(Theme.Type_.secondary)
                .foregroundStyle(Theme.Colors.accentText)
                .frame(minHeight: Theme.minHitTarget)
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
#endif
