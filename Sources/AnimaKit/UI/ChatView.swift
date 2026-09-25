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
        // Fase 4 (§5.8): propuesta proactiva del deseo. resolved oculta las acciones.
        public var isProactive: Bool = false
        public var intentionId: String?
        public var resolved: Bool = false
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

    private let loop: AgentLoop
    private let sessionId: SessionID
    private let desireEngine: DesireEngine?
    private let selfModel: SelfModel?
    private var shownIntentionIds: Set<String> = []
    private var lastUserText: String?

    public init(loop: AgentLoop, sessionId: SessionID, desireEngine: DesireEngine? = nil,
                selfModel: SelfModel? = nil) {
        self.loop = loop
        self.sessionId = sessionId
        self.desireEngine = desireEngine
        self.selfModel = selfModel
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
        await run(text: text, addUserBubble: true)
    }

    /// "Try again" del error card: reintenta el último turno sin duplicar la
    /// burbuja del usuario — el mensaje nunca se pierde.
    public func retry() async {
        guard let text = lastUserText, !isStreaming else { return }
        await run(text: text, addUserBubble: false)
    }

    private func run(text: String, addUserBubble: Bool) async {
        errorText = nil
        lastUserText = text
        if addUserBubble {
            messages.append(DisplayMessage(role: .user, text: text))
        }

        var assistant = DisplayMessage(role: .assistant, isStreaming: true)
        messages.append(assistant)
        let index = messages.count - 1
        isStreaming = true

        for await event in await loop.run(sessionId: sessionId, userText: text) {
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

// MARK: - Vista

public struct ChatView: View {
    @ObservedObject private var model: ChatViewModel
    @State private var expandedThoughts: Set<UUID> = []
    @State private var showMindSheet = false
    @State private var captureNotice: String?

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
                    .onChange(of: model.messages.last?.text) { _, _ in
                        if let last = model.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                composer
            }
        }
        .task {
            await model.loadMind()
            await model.loadProactiveIntentions()
        }
        .sheet(isPresented: $showMindSheet) {
            MindSheet(mind: model.mind)
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
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.Colors.accent)
                    .frame(width: 6, height: 6)
                Text("solo teléfono")
                    .font(Theme.Type_.label)
                    .kerning(0.66)
                    .foregroundStyle(Theme.Colors.textFaint)
            }
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
            Text(message.text)
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.text)
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
                .accessibilityIdentifier("chat.userMessage")
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
            Text(message.text)
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.text)
                .fixedSize(horizontal: false, vertical: true)
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
                .onSubmit { Task { await model.send() } }
                .accessibilityIdentifier("chat.input")

            Button {
                if hasDraft {
                    Task { await model.send() }
                } else {
                    captureNotice = "Las notas de voz llegan pronto; por ahora escríbele."
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
            .disabled(model.isStreaming && hasDraft)
            .accessibilityIdentifier("chat.send")
        }
        .padding(Theme.Space.screenInset)
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

    public init(mind: ChatViewModel.MindState) {
        self.mind = mind
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
                    keyValueRow("cuerpo", "solo teléfono", id: "body")
                    Divider().background(Theme.Colors.border)
                    keyValueRow("régimen", mind.regimeLabel, id: "regime")
                    Divider().background(Theme.Colors.border)
                    keyValueRow("ciclos vividos", "\(mind.cycles)", id: "cycles")
                }
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                .padding(.horizontal, Theme.Space.screenInset)

                Text("Vincular gafas · pronto")
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.textFaint)
                    .padding(.top, 4)
                Spacer(minLength: 0)
            }
            .padding(.top, Theme.Space.sectionGap)
        }
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
#endif
