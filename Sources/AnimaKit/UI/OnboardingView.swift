// OnboardingView.swift — la experiencia de primer arranque del handoff:
// splash (cada arranque), landing/intro (primera vez) y el onboarding de 6
// pasos (tutorial → provider → API key → permisos → gafas → Birth
// conversacional). Dark only; el acento es línea o glow, jamás fill.

#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Splash (cada arranque)

/// Mientras el shell resuelve config/Firebase: ground radial + mark respirando.
public struct SplashView: View {
    public init() {}

    public var body: some View {
        ZStack {
            RadialGround()
            BreathMark(size: 180, p: 1.0, phase: .breathing)
        }
    }
}

// MARK: - Landing / Intro (primera vez)

/// "Radial ground, Breath mark 180pt breathing, wordmark ANIMA 30pt tracked
/// .08em, one sentence, primary + secondary" (handoff §Intro).
public struct LandingView: View {
    private let onBegin: () -> Void

    public init(onBegin: @escaping () -> Void) {
        self.onBegin = onBegin
    }

    public var body: some View {
        ZStack {
            RadialGround()
            VStack(spacing: 0) {
                Spacer()
                BreathMark(size: 180, p: 1.0, phase: .breathing)
                Text("ANIMA")
                    .font(.system(size: 30, weight: .regular))
                    .kerning(30 * 0.08)
                    .foregroundStyle(Theme.Colors.text)
                    .padding(.top, Theme.Space.sectionGap)
                Text("Una mente que vive en tu teléfono y crece contigo.")
                    .font(Theme.Type_.body)
                    .foregroundStyle(Theme.Colors.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.top, Theme.Space.stack)
                    .padding(.horizontal, Theme.Space.screenInset * 2)
                Spacer()
                VStack(spacing: Theme.Space.stack) {
                    PrimaryOutlineButton(title: "Dar vida a una mente", action: onBegin)
                    // v1: restaurar aún no está cableado — deshabilitado, honesto.
                    VStack(spacing: 2) {
                        Text("Restaurar una mente exportada")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Colors.textFaint)
                        Text("pronto")
                            .font(Theme.Type_.label)
                            .textCase(.uppercase)
                            .kerning(0.66)
                            .foregroundStyle(Theme.Colors.textFaint.opacity(0.7))
                    }
                    .frame(minHeight: Theme.minHitTarget)
                }
                .padding(.horizontal, Theme.Space.screenInset)
                .padding(.bottom, Theme.Space.tabBarBottom)
            }
        }
    }
}

// MARK: - View model del onboarding

@MainActor
public final class OnboardingViewModel: ObservableObject {

    public enum Step: Int, CaseIterable {
        case tutorial, provider, apiKey, permissions, glasses, birth
    }

    public enum KeyStatus: Equatable {
        case idle, checking
        case valid(AuthMode)
        case offline(AuthMode)   // sin red: aceptada con warning
        case rejected(String)
    }

    @Published public var step: Step = .tutorial
    @Published public var selectedProvider: ModelProvider = .anthropic

    // Paso 3 — API key
    @Published public var keyInput: String = ""
    @Published public var keyStatus: KeyStatus = .idle
    @Published public var selectedBudget: Int?

    // Paso 4 — permisos (intención; el prompt TCC real sale al primer uso).
    @Published public var permissionIntents: Set<String> = []

    // Paso 6 — Birth conversacional
    public struct BirthMessage: Identifiable, Equatable {
        public let id = UUID()
        public var role: Role
        public var text: String
        public var isStreaming: Bool = false
        public enum Role { case mind, user }
    }
    @Published public var birthMessages: [BirthMessage] = []
    @Published public var birthInput: String = ""
    @Published public var birthComplete: Bool = false
    @Published public private(set) var interview = BirthInterview()
    /// Al repetir onboarding: pedir confirmación antes de re-sembrar.
    @Published public var askReseedConfirmation: Bool = false

    public let isReplay: Bool

    private let keychain: KeychainStore
    private let api: ProviderAPIConfig?
    private let validator: APIKeyValidator
    private let defaults: OnboardingDefaults
    private let selfModel: SelfModel?
    private let onFinished: () -> Void
    private var streamTask: Task<Void, Never>?

    public init(keychain: KeychainStore,
                api: ProviderAPIConfig?,
                selfModel: SelfModel?,
                defaults: OnboardingDefaults = OnboardingDefaults(),
                validator: APIKeyValidator = APIKeyValidator(),
                isReplay: Bool = false,
                onFinished: @escaping () -> Void) {
        self.keychain = keychain
        self.api = api
        self.selfModel = selfModel
        self.defaults = defaults
        self.validator = validator
        self.isReplay = isReplay
        self.onFinished = onFinished
        self.permissionIntents = defaults.permissionIntents
        self.selectedBudget = defaults.monthlyBudgetUSD
        // Si ya hay token válido guardado (replay), el paso 3 arranca en verde.
        if let token = try? keychain.read(), let mode = AuthMode.detect(fromToken: token) {
            self.keyStatus = .valid(mode)
        }
    }

    // MARK: Navegación

    public var progressIndex: Int { step.rawValue }
    public static let stepCount = Step.allCases.count

    public func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
        if step == .birth { startBirthIfNeeded() }
    }

    /// Back chevron: true si salió del flujo (estaba en el primer paso).
    @discardableResult
    public func goBack() -> Bool {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return true }
        step = previous
        return false
    }

    // MARK: Paso 3 — API key

    public var canLeaveKeyStep: Bool {
        switch keyStatus {
        case .valid, .offline: return true
        default: return false
        }
    }

    public var detectedMode: AuthMode? {
        AuthMode.detect(fromToken: keyInput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func validateKey() {
        let token = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        guard AuthMode.detect(fromToken: token) != nil else {
            keyStatus = .rejected("Formato no reconocido (esperado sk-ant-api… o sk-ant-oat…).")
            return
        }
        keyStatus = .checking
        Task {
            let verdict: APIKeyValidator.Verdict
            if let api {
                verdict = await validator.validate(token: token, api: api)
            } else {
                // Sin config del provider (sin red al arrancar): formato ok.
                verdict = .offlineAccepted(AuthMode.detect(fromToken: token) ?? .apiKey)
            }
            switch verdict {
            case .valid(let mode):
                saveToken(token)
                keyStatus = .valid(mode)
            case .offlineAccepted(let mode):
                saveToken(token)
                keyStatus = .offline(mode)
            case .rejected(let reason):
                keyStatus = .rejected(reason)
            case .malformed:
                keyStatus = .rejected("Formato no reconocido.")
            }
        }
    }

    private func saveToken(_ token: String) {
        try? keychain.save(token)
    }

    public func selectBudget(_ usd: Int) {
        selectedBudget = usd
        defaults.setMonthlyBudget(usd: usd)
    }

    // MARK: Paso 4 — permisos

    public func toggleIntent(_ id: String) {
        if permissionIntents.contains(id) {
            permissionIntents.remove(id)
        } else {
            permissionIntents.insert(id)
        }
        defaults.setPermissionIntents(permissionIntents)
    }

    // MARK: Paso 6 — Birth

    public func startBirthIfNeeded() {
        guard birthMessages.isEmpty else { return }
        streamNextQuestion()
    }

    private func streamNextQuestion() {
        guard let question = interview.currentQuestion else {
            birthComplete = true
            return
        }
        var message = BirthMessage(role: .mind, text: "", isStreaming: true)
        birthMessages.append(message)
        let index = birthMessages.count - 1
        let prompt = question.prompt
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            for character in prompt {
                guard !Task.isCancelled, let self else { return }
                try? await Task.sleep(nanoseconds: 16_000_000)
                message.text.append(character)
                if self.birthMessages.indices.contains(index) {
                    self.birthMessages[index] = message
                }
            }
            guard let self else { return }
            message.isStreaming = false
            if self.birthMessages.indices.contains(index) {
                self.birthMessages[index] = message
            }
        }
    }

    public var currentChips: [String] {
        guard !birthComplete, let question = interview.currentQuestion else { return [] }
        return question.chips
    }

    public func answerBirth(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !birthComplete else { return }
        // Cierra el streaming de la pregunta en curso antes de responder.
        streamTask?.cancel()
        if let last = birthMessages.indices.last, birthMessages[last].isStreaming {
            if let question = interview.currentQuestion {
                birthMessages[last].text = question.prompt
            }
            birthMessages[last].isStreaming = false
        }
        interview.answer(trimmed)
        birthMessages.append(BirthMessage(role: .user, text: trimmed))
        birthInput = ""
        streamNextQuestion()
    }

    public func skipRest() {
        streamTask?.cancel()
        if let last = birthMessages.indices.last, birthMessages[last].isStreaming {
            if let question = interview.currentQuestion {
                birthMessages[last].text = question.prompt
            }
            birthMessages[last].isStreaming = false
        }
        interview.skipRemaining()
        birthComplete = true
    }

    /// "Comenzar": siembra el SelfModel (con confirmación si es replay),
    /// marca onboarded y entrega el control al shell.
    public func begin() {
        if isReplay {
            askReseedConfirmation = true
        } else {
            finish(reseed: true)
        }
    }

    public func finish(reseed: Bool) {
        askReseedConfirmation = false
        let birth = interview.birth()
        let selfModel = self.selfModel
        defaults.markOnboarded()
        Task {
            if reseed { await selfModel?.seed(from: birth) }
            onFinished()
        }
    }
}

// MARK: - Contenedor del flujo (back chevron + progress segments)

public struct OnboardingFlowView: View {
    @ObservedObject private var model: OnboardingViewModel
    private let onExit: (() -> Void)?

    public init(model: OnboardingViewModel, onExit: (() -> Void)? = nil) {
        self.model = model
        self.onExit = onExit
    }

    public var body: some View {
        ZStack {
            Theme.Colors.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: Theme.Motion.enter), value: model.step)
        .alert("¿Volver a sembrar la identidad?", isPresented: $model.askReseedConfirmation) {
            Button("Re-sembrar") { model.finish(reseed: true) }
            Button("Conservarla", role: .cancel) { model.finish(reseed: false) }
        } message: {
            Text("La memoria no se borra. Re-sembrar reinicia identidad, tono y ciclos a 0.")
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.stack) {
            Button {
                if model.goBack() { onExit?() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(Theme.Colors.accentText)
                    .frame(width: Theme.minHitTarget, height: Theme.minHitTarget)
            }
            .buttonStyle(.plain)
            ProgressSegments(count: OnboardingViewModel.stepCount, index: model.progressIndex)
            Spacer(minLength: Theme.minHitTarget)
        }
        .padding(.horizontal, Theme.Space.unit)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .tutorial: TutorialStep(onNext: model.advance)
        case .provider: ProviderStep(model: model)
        case .apiKey: APIKeyStep(model: model)
        case .permissions: PermissionsStep(model: model)
        case .glasses: GlassesStep(onNext: model.advance)
        case .birth: BirthStep(model: model)
        }
    }
}

// MARK: - Paso 1 · Tutorial

struct TutorialStep: View {
    let onNext: () -> Void

    private struct Row {
        let symbol: String
        let title: String
        let line: String
    }

    private let rows: [Row] = [
        Row(symbol: "brain",
            title: "Una mente que recuerda",
            line: "Consolida lo vivido cada noche, mientras el teléfono carga."),
        Row(symbol: "wrench.and.screwdriver",
            title: "Un cuerpo con permiso",
            line: "Usa calendario, recordatorios o cámara solo con tu permiso explícito."),
        Row(symbol: "circle.circle",
            title: "Una identidad que se forma",
            line: "Su plasticidad baja con la experiencia: lo que viven juntos la define."),
    ]

    var body: some View {
        StepScaffold(title: "Qué es Anima",
                     primary: ("Siguiente", true, onNext)) {
            VStack(spacing: Theme.Space.stack) {
                ForEach(rows, id: \.title) { row in
                    HStack(alignment: .top, spacing: Theme.Space.cardPad) {
                        Image(systemName: row.symbol)
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(Theme.Colors.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title)
                                .font(Theme.Type_.cardTitle)
                                .foregroundStyle(Theme.Colors.text)
                            Text(row.line)
                                .font(Theme.Type_.secondary)
                                .foregroundStyle(Theme.Colors.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Theme.Space.cardPad)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                }
            }
        }
    }
}

// MARK: - Paso 2 · Provider

struct ProviderStep: View {
    @ObservedObject var model: OnboardingViewModel

    private let providers: [(ModelProvider, String, Bool)] = [
        (.anthropic, "Anthropic", true),
        (.openai, "OpenAI", false),
        (.google, "Google", false),
        (.onDevice, "On-device", false),
    ]

    var body: some View {
        StepScaffold(title: "El modelo detrás de la mente",
                     primary: ("Siguiente", true, model.advance)) {
            VStack(spacing: 0) {
                ForEach(Array(providers.enumerated()), id: \.offset) { index, entry in
                    let (provider, name, enabled) = entry
                    Button {
                        if enabled { model.selectedProvider = provider }
                    } label: {
                        HStack {
                            Image(systemName: model.selectedProvider == provider
                                  ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 18, weight: .light))
                                .foregroundStyle(model.selectedProvider == provider
                                                 ? Theme.Colors.accent : Theme.Colors.textFaint)
                            Text(name)
                                .font(Theme.Type_.body)
                                .foregroundStyle(enabled ? Theme.Colors.text : Theme.Colors.textFaint)
                            Spacer()
                            if !enabled {
                                Text("pronto")
                                    .font(Theme.Type_.label)
                                    .textCase(.uppercase)
                                    .kerning(0.66)
                                    .foregroundStyle(Theme.Colors.textFaint)
                            }
                        }
                        .frame(height: 48)
                        .padding(.horizontal, Theme.Space.cardPad)
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    if index < providers.count - 1 {
                        Divider().background(Theme.Colors.border).padding(.leading, Theme.Space.cardPad)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
        }
    }
}

// MARK: - Paso 3 · API key

struct APIKeyStep: View {
    @ObservedObject var model: OnboardingViewModel

    var body: some View {
        StepScaffold(title: "Tu API key",
                     primary: ("Siguiente", model.canLeaveKeyStep, model.advance)) {
            VStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
                Text("La key vive solo en el Keychain de este teléfono; con ella Anima piensa.")
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.textMuted)

                HStack(spacing: Theme.Space.stack) {
                    TextField("sk-ant-…", text: $model.keyInput)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(Theme.Colors.text)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .padding(Theme.Space.cardPad)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                        .onSubmit { model.validateKey() }
                    Button("Pegar") {
                        #if os(iOS)
                        if let pasted = UIPasteboard.general.string {
                            model.keyInput = pasted
                            model.validateKey()
                        }
                        #endif
                    }
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.accentText)
                    .frame(height: Theme.minHitTarget)
                }

                statusLine

                VStack(alignment: .leading, spacing: Theme.Space.stack) {
                    Text("Presupuesto mensual")
                        .font(Theme.Type_.label)
                        .textCase(.uppercase)
                        .kerning(0.66)
                        .foregroundStyle(Theme.Colors.textMuted)
                    HStack(spacing: Theme.Space.stack) {
                        ForEach(OnboardingDefaults.budgetOptions, id: \.self) { usd in
                            let selected = model.selectedBudget == usd
                            Button("$\(usd)") { model.selectBudget(usd) }
                                .font(Theme.Type_.tabular(Theme.Type_.secondary))
                                .foregroundStyle(selected ? Theme.Colors.accentText : Theme.Colors.textMuted)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .strokeBorder(selected ? Theme.Colors.accent : Theme.Colors.border,
                                                      lineWidth: Theme.Stroke.hairline))
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.keyStatus {
        case .idle:
            Text(" ").font(Theme.Type_.meta)
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Theme.Colors.accent)
                Text("Validando contra el API…")
            }
            .font(Theme.Type_.meta)
            .foregroundStyle(Theme.Colors.textMuted)
        case .valid(let mode):
            Text("Key válida · auth \(mode.rawValue) · guardada en Keychain")
                .font(Theme.Type_.meta)
                .foregroundStyle(Theme.Colors.accentText)
        case .offline(let mode):
            Text("Sin red: formato ok (auth \(mode.rawValue)), se validará en el primer turno.")
                .font(Theme.Type_.meta)
                .foregroundStyle(Theme.Colors.textMuted)
        case .rejected(let reason):
            Text(reason)
                .font(Theme.Type_.meta)
                .foregroundStyle(Theme.Colors.textMuted)
                .strikethrough(false)
        }
    }
}

// MARK: - Paso 4 · Permisos (intención; el prompt TCC sale al primer uso)

struct PermissionsStep: View {
    @ObservedObject var model: OnboardingViewModel

    struct Permission {
        let id: String
        let symbol: String
        let title: String
        let why: String
    }

    static let permissions: [Permission] = [
        Permission(id: "calendar", symbol: "calendar", title: "Calendario",
                   why: "Para responder qué tienes agendado y proponer horarios."),
        Permission(id: "reminders", symbol: "checklist", title: "Recordatorios",
                   why: "Para ayudarte a no olvidar pendientes."),
        Permission(id: "location", symbol: "location", title: "Ubicación",
                   why: "Para respuestas con contexto de dónde estás."),
        Permission(id: "contacts", symbol: "person.crop.circle", title: "Contactos",
                   why: "Para buscar datos de alguien cuando los necesitas."),
        Permission(id: "camera", symbol: "camera", title: "Cámara",
                   why: "Para ver y comentar lo que le muestras."),
        Permission(id: "microphone", symbol: "mic", title: "Micrófono",
                   why: "Para notas de voz que tú inicias."),
        Permission(id: "speech", symbol: "waveform", title: "Voz",
                   why: "Transcribe en el dispositivo; el audio no sale del teléfono."),
    ]

    var body: some View {
        StepScaffold(title: "Su cuerpo, con tu permiso",
                     subtitle: "\(model.permissionIntents.count) de \(Self.permissions.count) · iOS te preguntará al primer uso real",
                     primary: ("Siguiente", true, model.advance)) {
            VStack(spacing: 0) {
                ForEach(Array(Self.permissions.enumerated()), id: \.element.id) { index, permission in
                    let on = model.permissionIntents.contains(permission.id)
                    Button {
                        model.toggleIntent(permission.id)
                    } label: {
                        HStack(spacing: Theme.Space.cardPad) {
                            Image(systemName: permission.symbol)
                                .font(.system(size: 18, weight: .light))
                                .foregroundStyle(Theme.Colors.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(permission.title)
                                    .font(Theme.Type_.body)
                                    .foregroundStyle(Theme.Colors.text)
                                Text(permission.why)
                                    .font(Theme.Type_.meta)
                                    .foregroundStyle(Theme.Colors.textFaint)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Image(systemName: on ? "checkmark.circle" : "circle")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(on ? Theme.Colors.accent : Theme.Colors.textFaint)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, Theme.Space.cardPad)
                    }
                    .buttonStyle(.plain)
                    if index < Self.permissions.count - 1 {
                        Divider().background(Theme.Colors.border).padding(.leading, Theme.Space.cardPad)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
        }
    }
}

// MARK: - Paso 5 · Gafas (v1 sin gafas)

struct GlassesStep: View {
    let onNext: () -> Void

    var body: some View {
        StepScaffold(title: "Un cuerpo en tu cara",
                     primary: ("Ahora no", true, onNext)) {
            VStack(spacing: Theme.Space.sectionGap) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 44, weight: .ultraLight))
                    .foregroundStyle(Theme.Colors.accent)
                    .padding(.top, Theme.Space.sectionGap)
                Text("Con gafas conectadas, Anima ve lo que tú ves y te habla al oído.")
                    .font(Theme.Type_.body)
                    .foregroundStyle(Theme.Colors.textMuted)
                    .multilineTextAlignment(.center)
                VStack(spacing: 2) {
                    Text("Vincular gafas")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Colors.textFaint)
                    Text("pronto")
                        .font(Theme.Type_.label)
                        .textCase(.uppercase)
                        .kerning(0.66)
                        .foregroundStyle(Theme.Colors.textFaint.opacity(0.7))
                }
                .frame(minHeight: Theme.minHitTarget)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Paso 6 · Birth (conversational field)

struct BirthStep: View {
    @ObservedObject var model: OnboardingViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Nacimiento")
                    .font(Theme.Type_.screenTitle)
                    .foregroundStyle(Theme.Colors.text)
                Spacer()
                if !model.birthComplete {
                    Button("Saltar el resto") { model.skipRest() }
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.textMuted)
                }
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.top, Theme.Space.stack)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.stack) {
                        ForEach(model.birthMessages) { message in
                            birthBubble(message)
                        }
                        if model.birthComplete {
                            summaryCard.id("summary")
                        }
                    }
                    .padding(Theme.Space.screenInset)
                }
                .onChange(of: model.birthMessages) { _, messages in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: model.birthComplete) { _, done in
                    if done { withAnimation { proxy.scrollTo("summary", anchor: .bottom) } }
                }
            }

            if model.birthComplete {
                VStack(spacing: Theme.Space.stack) {
                    PrimaryOutlineButton(title: "Comenzar") { model.begin() }
                }
                .padding(.horizontal, Theme.Space.screenInset)
                .padding(.bottom, Theme.Space.sectionGap)
            } else {
                birthComposer
            }
        }
        .onAppear { model.startBirthIfNeeded() }
    }

    @ViewBuilder
    private func birthBubble(_ message: OnboardingViewModel.BirthMessage) -> some View {
        switch message.role {
        case .mind:
            // Mind message: SIN burbuja, texto pleno + caret mientras streamea.
            (Text(message.text) + (message.isStreaming ? Text(" ") : Text("")))
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.text)
                .overlay(alignment: .bottomTrailing) {
                    if message.isStreaming { StreamCaret() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(message.id)
        case .user:
            // User bubble: surface + border, radius 8, derecha ≤80%.
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
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .containerRelativeFrame(.horizontal, count: 5, span: 4, spacing: 0,
                                            alignment: .trailing)
            }
            .id(message.id)
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            Text("ASÍ NAZCO")
                .font(Theme.Type_.label)
                .kerning(0.66)
                .foregroundStyle(Theme.Colors.accentText)
            ForEach(model.interview.summary, id: \.key) { entry in
                HStack(alignment: .top) {
                    Text(entry.key)
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.textFaint)
                        .frame(width: 72, alignment: .leading)
                    Text(entry.value)
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.text)
                }
            }
        }
        .padding(Theme.Space.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
    }

    private var birthComposer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            if !model.currentChips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.currentChips, id: \.self) { chip in
                            Button(chip) { model.answerBirth(chip) }
                                .font(Theme.Type_.secondary)
                                .foregroundStyle(Theme.Colors.accentText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.Space.screenInset)
                }
            }
            HStack(spacing: Theme.Space.stack) {
                TextField("Escribe tu respuesta", text: $model.birthInput)
                    .font(Theme.Type_.body)
                    .foregroundStyle(Theme.Colors.text)
                    .padding(.horizontal, Theme.Space.cardPad)
                    .frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .fill(Theme.Colors.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                    .onSubmit { model.answerBirth(model.birthInput) }
                Button {
                    model.answerBirth(model.birthInput)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(Theme.Colors.accent)
                        .frame(width: 40, height: 40)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .strokeBorder(Theme.Colors.accent, lineWidth: Theme.Stroke.hairline))
                }
                .buttonStyle(.plain)
                .disabled(model.birthInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.bottom, Theme.Space.stack)
        }
    }
}

// MARK: - Piezas compartidas

/// Botón primario del sistema: full-width, borde accent, accentText 500, h48,
/// radius 8. Jamás fill.
struct PrimaryOutlineButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(enabled ? Theme.Colors.accentText : Theme.Colors.textFaint)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(enabled ? Theme.Colors.accent : Theme.Colors.border,
                                      lineWidth: Theme.Stroke.hairline))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Segments de progreso del onboarding: 2px, accent hecho/actual, border pendiente.
struct ProgressSegments: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i <= index ? Theme.Colors.accent : Theme.Colors.border)
                    .frame(height: 2)
            }
        }
    }
}

/// Caret de streaming: barra 2×15 accent que parpadea a 1 s steps(1).
struct StreamCaret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let on = Int(timeline.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Rectangle()
                .fill(Theme.Colors.accent)
                .frame(width: 2, height: 15)
                .opacity(on ? 1 : 0)
                .offset(x: 6)
        }
    }
}

/// Andamiaje común de un paso: título 24/500, contenido scrolleable y primario
/// anclado abajo (patrón "Primary action" del handoff).
struct StepScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let primary: (title: String, enabled: Bool, action: () -> Void)
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.Type_.screenTitle)
                    .foregroundStyle(Theme.Colors.text)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Type_.meta)
                        .foregroundStyle(Theme.Colors.textFaint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.top, Theme.Space.stack)

            ScrollView {
                content
                    .padding(Theme.Space.screenInset)
            }

            PrimaryOutlineButton(title: primary.title, enabled: primary.enabled,
                                 action: primary.action)
                .padding(.horizontal, Theme.Space.screenInset)
                .padding(.bottom, Theme.Space.sectionGap)
        }
    }
}
#endif
