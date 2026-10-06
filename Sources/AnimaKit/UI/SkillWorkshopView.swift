// SkillWorkshopView.swift — el taller conversacional de skills (FIX A). Patrón
// "Conversational field" (components.md; el mismo del Birth): mind messages
// streameados sin burbuja, respuestas del dueño como burbujas, chips, y el
// borrador vivo como card colapsable monoespaciada. "Guardar" escribe a
// Documents/skills. Sesión efímera: nada de esto entra al hilo principal.

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class SkillWorkshopViewModel: ObservableObject, Identifiable, Hashable {
    public struct Message: Identifiable, Equatable, Sendable {
        public enum Role: Sendable, Equatable { case mind, user }
        public let id = UUID()
        public var role: Role
        public var text: String
        public var isStreaming = false
        public var isError = false
    }

    public static let openingCreate = "Enséñame algo. ¿Qué quieres que aprenda a hacer?"
    public static let openingEdit = "Esta es la skill hoy. ¿Qué cambiamos?"
    public static let drafting = "Redactando el borrador…"
    public static let noCortex = "No hay un modelo disponible para redactar ahora mismo."

    @Published public private(set) var messages: [Message] = []
    @Published public var input = ""
    @Published public private(set) var isStreaming = false
    /// Markdown del borrador vigente (el último bloque <skill> del córtex).
    @Published public private(set) var draft: String?
    @Published public private(set) var saved = false
    @Published public private(set) var errorText: String?
    @Published public private(set) var isListening = false
    @Published public private(set) var liveTranscript = ""

    public let mode: SkillWorkshopMode
    private let library: SkillLibrary
    private let practiceSuccesses: Int
    private let makeSession: ((SkillWorkshopMode) throws -> SkillWorkshopSession)?
    private var session: SkillWorkshopSession?
    private var started = false
    private var voiceCancelled = false
    public var voice: (any VoiceCapturePort)?
    /// Guardar/eliminar: la lista de Skills se relee.
    public var onChanged: (() -> Void)?

    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
    public nonisolated static func == (a: SkillWorkshopViewModel, b: SkillWorkshopViewModel) -> Bool { a === b }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    public init(mode: SkillWorkshopMode, library: SkillLibrary, practiceSuccesses: Int = 0,
                makeSession: ((SkillWorkshopMode) throws -> SkillWorkshopSession)?) {
        self.mode = mode
        self.library = library
        self.practiceSuccesses = practiceSuccesses
        self.makeSession = makeSession
        if case .edit(_, let markdown) = mode { draft = markdown }
    }

    public var isEditing: Bool { mode.originalName != nil }

    /// El primer mind message (local, como el Birth). `animated: false` en tests.
    public func start(animated: Bool = true) async {
        guard !started else { return }
        started = true
        let opening = isEditing ? Self.openingEdit : Self.openingCreate
        guard animated else {
            messages.append(Message(role: .mind, text: opening))
            return
        }
        messages.append(Message(role: .mind, text: "", isStreaming: true))
        let index = messages.count - 1
        for word in opening.split(separator: " ", omittingEmptySubsequences: false) {
            try? await Task.sleep(nanoseconds: 35_000_000)
            messages[index].text += (messages[index].text.isEmpty ? "" : " ") + word
        }
        messages[index].isStreaming = false
    }

    // MARK: Chips

    public var chips: [String] {
        guard !isStreaming else { return [] }
        if draft != nil, messages.contains(where: { $0.role == .user }) {
            return ["Así está bien", "Hazla más corta", "Agrega un paso"]
        }
        if isEditing { return ["Cambia cuándo usarla", "Agrega un paso", "Hazla más corta"] }
        if !messages.contains(where: { $0.role == .user }) {
            return ["Preparar mis reuniones", "Resumen de mi semana", "Regar las plantas"]
        }
        return []
    }

    // MARK: Borrador

    /// La skill que guardaría "Guardar" (front-matter normalizado), si parsea.
    public var draftSkill: Skill? {
        draft.flatMap { SkillEngine.parse(normalizedDraft(from: $0)) }
    }

    public var canSave: Bool { !isStreaming && draftSkill != nil }

    /// Renombrar = skill nueva: la práctica (por nombre) empieza de cero.
    public var renameWarning: String? {
        guard let original = mode.originalName, let name = draftSkill?.name, name != original else { return nil }
        let practice = practiceSuccesses > 0
            ? " (\(practiceSuccesses == 1 ? "1 éxito" : "\(practiceSuccesses) éxitos") de práctica se pierden)"
            : ""
        return "Renombrarla a \"\(name)\" la vuelve una skill nueva: su práctica empieza de cero\(practice)."
    }

    private func normalizedDraft(from markdown: String) -> String {
        let fallback = mode.originalName
            ?? messages.first(where: { $0.role == .user })?.text
            ?? "skill"
        return SkillMarkdown.normalized(markdown, fallbackName: fallback)
    }

    // MARK: Turnos

    public func send(_ raw: String? = nil) async {
        let text = (raw ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        if raw == nil { input = "" }
        errorText = nil
        messages.append(Message(role: .user, text: text))
        guard let session = currentSession() else {
            messages.append(Message(role: .mind, text: Self.noCortex, isError: true))
            return
        }
        isStreaming = true
        messages.append(Message(role: .mind, text: "", isStreaming: true))
        let index = messages.count - 1
        var full = ""
        for await event in await session.loop.run(sessionId: session.sessionId, content: [.text(text)]) {
            switch event {
            case .textDelta(let delta):
                full += delta
                if let block = SkillMarkdown.extractBlock(from: full) { draft = block }
                let visible = SkillMarkdown.strippingBlocks(full)
                messages[index].text = visible.isEmpty ? Self.drafting : visible
            case .error(let message):
                messages[index].isError = true
                if full.isEmpty { messages[index].text = message }
            case .refused:
                messages[index].isError = true
                if full.isEmpty { messages[index].text = "Prefiero no redactar eso. ¿Lo planteamos de otra forma?" }
            case .stopped(let stop):
                errorText = "Turno detenido: \(stop)"
            default:
                break
            }
        }
        if let block = SkillMarkdown.extractBlock(from: full) { draft = block }
        let visible = SkillMarkdown.strippingBlocks(full)
        if !visible.isEmpty {
            messages[index].text = visible
        } else if !messages[index].isError {
            messages[index].text = draft == nil ? "…" : "Aquí va el borrador. ¿Algo más o lo cambio?"
        }
        messages[index].isStreaming = false
        isStreaming = false
    }

    private func currentSession() -> SkillWorkshopSession? {
        if let session { return session }
        guard let makeSession else { return nil }
        session = try? makeSession(mode)
        return session
    }

    // MARK: Guardar / eliminar

    @discardableResult
    public func save() -> Bool {
        guard canSave, let draft else { return false }
        do {
            try library.save(normalizedDraft(from: draft), replacing: mode.originalName)
            saved = true
            onChanged?()
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    public func delete() {
        guard let name = mode.originalName else { return }
        do {
            try library.delete(named: name)
            saved = true
            onChanged?()
        } catch {
            errorText = "No se pudo eliminar: \(error.localizedDescription)"
        }
    }

    // MARK: Voz (mic del composer → mismo pipeline que el chat)

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

    public func finishVoice() {
        guard isListening else { return }
        voice?.finish()
    }

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
        guard !cancelled, let transcript, !transcript.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        await send(transcript)
    }
}

// MARK: - Vista

struct SkillWorkshopView: View {
    @ObservedObject var model: SkillWorkshopViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draftExpanded = true
    @State private var confirmDelete = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            Theme.Colors.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Theme.Space.stack) {
                            ForEach(model.messages) { message in
                                bubble(message).id(message.id)
                            }
                            if let draft = model.draft {
                                draftCard(draft).id("draft")
                            }
                        }
                        .padding(Theme.Space.screenInset)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: model.messages.last?.text) { _, _ in
                        withAnimation {
                            if model.draft != nil {
                                proxy.scrollTo("draft", anchor: .bottom)
                            } else if let last = model.messages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
                footer
            }
        }
        .navigationTitle(model.isEditing ? "Editar skill" : "Nueva skill")
        .navigationBarTitleDisplayModeInline()
        .toolbar {
            if model.isEditing {
                ToolbarItem(placement: .primaryAction) {
                    Button("Eliminar") { confirmDelete = true }
                        .foregroundStyle(Theme.Colors.textMuted)
                        .accessibilityIdentifier("workshop.delete")
                }
            }
        }
        .confirmationDialog("¿Eliminar \(model.mode.originalName ?? "esta skill")?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Eliminar", role: .destructive) { model.delete() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se borra su archivo de Documents/skills. Su práctica queda en el historial por si vuelve con el mismo nombre.")
        }
        .task { await model.start() }
        .onChange(of: model.saved) { _, saved in if saved { dismiss() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workshop.screen")
    }

    @ViewBuilder
    private func bubble(_ message: SkillWorkshopViewModel.Message) -> some View {
        switch message.role {
        case .mind:
            HStack(alignment: .bottom, spacing: 4) {
                if message.isStreaming && message.text.isEmpty {
                    ThinkingIndicator()
                } else {
                    Text(message.text)
                        .font(Theme.Type_.body)
                        .foregroundStyle(message.isError ? Theme.Colors.textMuted : Theme.Colors.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if message.isStreaming { StreamCaret() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("workshop.mindMessage")
            .accessibilityValue(message.isStreaming ? "streaming" : "done")
        case .user:
            HStack {
                Spacer(minLength: 0)
                Text(message.text)
                    .font(Theme.Type_.body)
                    .foregroundStyle(Theme.Colors.text)
                    .padding(Theme.Space.cardPad)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.Colors.surface))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                    .containerRelativeFrame(.horizontal, count: 5, span: 4, spacing: 0, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("workshop.userMessage")
            }
        }
    }

    /// Borrador vivo: card colapsable con el markdown monoespaciado.
    private func draftCard(_ draft: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { draftExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(Theme.Colors.textFaint)
                        .rotationEffect(.degrees(draftExpanded ? 90 : 0))
                    Text("BORRADOR")
                        .font(Theme.Type_.label)
                        .kerning(0.66)
                        .foregroundStyle(Theme.Colors.accentText)
                    if let name = model.draftSkill?.name {
                        Text("· \(name)")
                            .font(Theme.Type_.meta)
                            .foregroundStyle(Theme.Colors.textMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workshop.draft.toggle")
            if draftExpanded {
                SkillMarkdownCard(markdown: draft)
            }
        }
        .padding(Theme.Space.cardPad)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(Theme.Colors.accent, lineWidth: Theme.Stroke.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workshop.draft")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            if let warning = model.renameWarning {
                Text(warning)
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.accentText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.screenInset)
                    .accessibilityIdentifier("workshop.renameWarning")
            }
            if let error = model.errorText {
                Text(error)
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textMuted)
                    .padding(.horizontal, Theme.Space.screenInset)
            }
            if !model.chips.isEmpty, !model.isListening {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.chips, id: \.self) { chip in
                            Button(chip) { Task { await model.send(chip) } }
                                .font(Theme.Type_.secondary)
                                .foregroundStyle(Theme.Colors.accentText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .overlay(RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("workshop.chip.\(chip)")
                        }
                    }
                    .padding(.horizontal, Theme.Space.screenInset)
                }
            }
            if model.isListening {
                ListeningBar(transcript: model.liveTranscript,
                             onDone: { model.finishVoice() },
                             onCancel: { model.cancelVoice() })
            } else {
                composer
            }
            if model.canSave {
                PrimaryOutlineButton(title: model.isEditing ? "Guardar cambios" : "Guardar skill") {
                    inputFocused = false
                    model.save()
                }
                .accessibilityIdentifier("workshop.save")
                .padding(.horizontal, Theme.Space.screenInset)
                .padding(.bottom, Theme.Space.stack)
            }
        }
    }

    private var hasDraftInput: Bool { !model.input.trimmingCharacters(in: .whitespaces).isEmpty }

    private var composer: some View {
        HStack(spacing: Theme.Space.stack) {
            TextField(model.isEditing ? "Qué cambiamos" : "Escribe tu respuesta", text: $model.input, axis: .vertical)
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.text)
                .lineLimit(1...4)
                .padding(.horizontal, Theme.Space.cardPad)
                .padding(.vertical, 10)
                .frame(minHeight: 40)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.Colors.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                .focused($inputFocused)
                .onSubmit { Task { await model.send() } }
                .accessibilityIdentifier("workshop.input")
            Button {
                if hasDraftInput {
                    inputFocused = false
                    Task { await model.send() }
                } else {
                    inputFocused = false
                    model.startVoice()
                }
            } label: {
                Image(systemName: hasDraftInput ? "arrow.up" : "mic")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(width: 40, height: 40)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(Theme.Colors.accent, lineWidth: Theme.Stroke.hairline))
            }
            .buttonStyle(.plain)
            .disabled(model.isStreaming || (!hasDraftInput && model.voice == nil))
            .accessibilityLabel(hasDraftInput ? "Enviar" : "Hablar")
            .accessibilityIdentifier(hasDraftInput ? "workshop.send" : "workshop.mic")
        }
        .padding(.horizontal, Theme.Space.screenInset)
        .padding(.bottom, Theme.Space.stack)
    }
}
#endif
