// SettingsView.swift — token por provider → ProviderTokenStore, el provider
// remoto activo, el AuthMode detectado y la vista de costos reales desde
// Telemetry (§6, §7). Dark-only, tokens de Theme.

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var tokenInput: String = ""
    @Published public var detectedMode: AuthMode?
    @Published public var statusText: String = ""
    @Published public var costs: [Telemetry.CostRow] = []
    /// Una fila por modelo, con nombre para humanos (la vista de costos).
    public var modelCosts: [Telemetry.ModelCostRow] { Telemetry.byModel(costs) }
    @Published public var totalCost: Double = 0
    @Published public var monthlyBudgetUSD: Int?
    // Modo de operación (§4.9): cambia entre los 3 sin re-onboarding.
    @Published public private(set) var mode: OperatingMode
    @Published public private(set) var onDeviceAvailability: OnDeviceAvailability
    @Published public private(set) var hasToken: Bool = false
    @Published public var modeNotice: String?
    /// Provider remoto activo (Claude/OpenAI/Gemini) y los que tienen key guardada.
    @Published public private(set) var remoteProvider: ModelProvider
    @Published public private(set) var savedRemotes: Set<ModelProvider> = []
    /// A qué provider va la key del campo de texto.
    @Published public var tokenTarget: ModelProvider
    /// Ajustes → Modelo: UNA fila por provider (ProviderRoster).
    @Published public private(set) var rows: [ProviderRow] = []
    /// La fila con su campo de key expandido inline.
    @Published public private(set) var editing: ModelProvider?
    @Published public var keyInput: String = ""
    /// Error de validación de la fila en edición (nil = sin error).
    @Published public private(set) var keyError: String?
    @Published public private(set) var checkingKey = false
    /// Config del API por provider para validar la key como el onboarding
    /// (vacío = sin red / `--uitest`: se acepta con el formato ok).
    public var apis: [ModelProvider: ProviderAPIConfig] = [:]
    public var validator = APIKeyValidator()

    private let keychain: ProviderTokenStore
    private let telemetry: Telemetry
    private let onboardingDefaults: OnboardingDefaults
    /// "Repetir onboarding": re-corre el flujo sin borrar memoria (el Birth
    /// re-siembra solo si el dueño confirma). Lo cablea el shell.
    public var onReplayOnboarding: (() -> Void)?
    /// Sección Cuenta (Sign in with Apple); la inyecta el shell.
    public var account: AccountViewModel?
    /// Sección Skills (§5.7); la inyecta el shell con el SkillEngine vivo.
    public var skills: SkillsViewModel?
    /// Sección Gafas (track G); la inyecta el shell con el GlassesBody vivo.
    public var glasses: GlassesViewModel?
    /// Sección Notificaciones (capa proactiva); la inyecta el shell.
    public var notifications: NotificationsSettingsModel?
    /// "Por aprobar" en Mente (la inyecta el shell).
    public var approvals: ApprovalsInboxViewModel?
    /// Pila del hub: el shell la empuja (aviso del chat → Mente).
    @Published public var path: [SettingsRoute] = []
    /// "Simular una noche": un ciclo del Consolidator en foreground (lo cablea el shell).
    public var nightSimulator: NightSimulator?
    /// Al terminar el ciclo: Memoria/Metas refrescan si están instanciadas.
    public var onNightSimulated: (() -> Void)?
    /// Arranca la noche simulada (la app abre la Live Activity del sueño).
    public var onNightStarted: (() -> Void)?
    @Published public private(set) var simulatingNight = false
    @Published public private(set) var nightSummary: String?
    /// Hub (FIX F): el SelfModel vivo alimenta el resumen de la fila Mente.
    public var selfModel: SelfModel?
    @Published public private(set) var mindSummary: String = ""
    @Published public private(set) var monthCost: Double = 0

    /// El shell re-cablea el harness con el nuevo modo (sin re-onboarding).
    public var onModeChanged: ((OperatingMode) -> Void)?
    private let availabilityProbe: () -> OnDeviceAvailability

    public init(keychain: ProviderTokenStore, telemetry: Telemetry,
                onboardingDefaults: OnboardingDefaults = OnboardingDefaults(),
                availability: @escaping () -> OnDeviceAvailability = { OnDeviceAvailability.current() }) {
        self.keychain = keychain
        self.telemetry = telemetry
        self.onboardingDefaults = onboardingDefaults
        self.availabilityProbe = availability
        self.mode = onboardingDefaults.modeStore.mode
        self.onDeviceAvailability = availability()
        let remote = onboardingDefaults.remoteStore.provider
        self.remoteProvider = remote
        self.tokenTarget = remote
    }

    // MARK: Modo

    /// Si el modo se puede elegir ahora; si no, el porqué.
    public func blocker(for mode: OperatingMode) -> String? {
        if mode.requiresOnDevice, let reason = onDeviceAvailability.reason {
            return reason
        }
        if mode.requiresToken, !hasToken {
            return "Requiere tu API key de \(remoteProvider.displayName) (en su fila)."
        }
        return nil
    }

    /// Si se puede activar ese provider remoto; si no, el porqué.
    public func remoteBlocker(for provider: ModelProvider) -> String? {
        savedRemotes.contains(provider) ? nil : "Agrega primero la key de \(provider.displayName) en su fila."
    }

    /// Cambia el córtex remoto (requiere su key guardada). Re-cablea el shell.
    public func selectRemote(_ provider: ModelProvider) {
        guard provider.isRemote else { return }
        if let reason = remoteBlocker(for: provider) {
            modeNotice = reason
            tokenTarget = provider
            return
        }
        modeNotice = nil
        guard provider != remoteProvider else { return }
        onboardingDefaults.remoteStore.set(provider)
        remoteProvider = provider
        tokenTarget = provider
        refreshTokenState()
        onModeChanged?(mode)
    }

    public func select(_ newMode: OperatingMode) {
        refreshAvailability()
        if let reason = blocker(for: newMode) {
            modeNotice = reason
            return
        }
        modeNotice = nil
        guard newMode != mode else { return }
        onboardingDefaults.modeStore.set(newMode)
        mode = newMode
        refreshRows()
        onModeChanged?(newMode)
    }

    public func refreshAvailability() {
        onDeviceAvailability = availabilityProbe()
    }

    /// Qué corre dónde en un modo: (qué, dónde).
    public static func placement(for mode: OperatingMode) -> [(what: String, backend: ProviderBackend)] {
        [
            ("Conversación", ProviderSelector.plannedBackend(mode: mode, turn: .interactive)),
            ("Sueño, pulsos y destilado", ProviderSelector.plannedBackend(mode: mode, turn: .consolidation)),
        ]
    }

    public func simulateNight() async {
        guard let nightSimulator, !simulatingNight else { return }
        simulatingNight = true
        nightSummary = nil
        onNightStarted?()
        if let summary = await nightSimulator.run() {
            nightSummary = summary
            onNightSimulated?()
        }
        await refreshMind()
        simulatingNight = false
    }

    public func replayOnboarding() {
        onboardingDefaults.markOnboarded(false)
        onReplayOnboarding?()
    }

    public func load() {
        mode = onboardingDefaults.modeStore.mode
        remoteProvider = onboardingDefaults.remoteStore.provider
        tokenTarget = remoteProvider
        refreshAvailability()
        refreshTokenState()
        monthlyBudgetUSD = onboardingDefaults.monthlyBudgetUSD
        refreshCosts()
    }

    // MARK: Lista de providers (una fila por provider)

    /// Radio de una fila: local = Solo teléfono; remota = ese provider (modo
    /// remoto, o Híbrido si ya lo era). Sin key, abre su campo.
    public func activate(_ provider: ModelProvider) {
        refreshAvailability()
        if provider == .onDevice {
            select(.onDeviceOnly)
            refreshRows()
            return
        }
        guard savedRemotes.contains(provider) else {
            beginEditing(provider)
            return
        }
        modeNotice = nil
        let newMode: OperatingMode = mode == .onDeviceOnly ? .remote : mode
        guard provider != remoteProvider || newMode != mode else { return }
        onboardingDefaults.remoteStore.set(provider)
        onboardingDefaults.modeStore.set(newMode)
        remoteProvider = provider
        tokenTarget = provider
        mode = newMode
        refreshTokenState()
        onModeChanged?(newMode)
    }

    /// Toggle Híbrido (debajo de la lista): solo con un remoto activo.
    public func setHybrid(_ on: Bool) {
        guard mode != .onDeviceOnly else { return }
        select(on ? .hybrid : .remote)
    }

    public func beginEditing(_ provider: ModelProvider) {
        guard provider.isRemote else { return }
        editing = provider
        keyInput = ""
        keyError = nil
    }

    public func cancelEditing() {
        editing = nil
        keyInput = ""
        keyError = nil
    }

    /// Guardar de la fila expandida: formato → validación contra el API (como el
    /// onboarding; sin red se acepta) → Keychain → la fila colapsa y se actualiza.
    public func saveKey() async {
        guard let provider = editing else { return }
        let token = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        guard provider.acceptsTokenFormat(token) else {
            keyError = provider == .anthropic
                ? "Formato no reconocido (esperado sk-ant-api… o sk-ant-oat…)."
                : "Formato no reconocido (sin espacios)."
            return
        }
        checkingKey = true
        let verdict: APIKeyValidator.Verdict
        if let api = apis[provider] {
            verdict = await validator.validate(token: token, provider: provider, api: api)
        } else {
            verdict = .offlineAccepted(provider.authMode(forToken: token) ?? .apiKey)
        }
        checkingKey = false
        switch verdict {
        case .valid, .offlineAccepted:
            do {
                try keychain.save(token, for: provider)
            } catch {
                keyError = "Error al guardar: \(error.localizedDescription)"
                return
            }
            cancelEditing()
            refreshTokenState()
            if provider == remoteProvider, mode != .onDeviceOnly { onModeChanged?(mode) }
        case .rejected(let reason):
            keyError = reason
        case .malformed:
            keyError = "Formato no reconocido."
        }
    }

    /// Borra la key (con confirmación en la vista). Si era la ACTIVA, la
    /// selección cae al siguiente remoto con key o al modelo local.
    public func deleteKey(_ provider: ModelProvider) {
        guard provider.isRemote else { return }
        try? keychain.delete(provider)
        if editing == provider { cancelEditing() }
        let wasActive = provider == remoteProvider && mode != .onDeviceOnly
        refreshTokenState()
        guard wasActive else { return }
        refreshAvailability()
        switch ProviderRoster.fallback(afterDeleting: provider, saved: savedRemotes, local: onDeviceAvailability) {
        case .onDevice?: select(.onDeviceOnly)
        case let next?: activate(next)
        case nil: onModeChanged?(mode)
        }
        refreshRows()
    }

    private func refreshRows() {
        var tokens: [ModelProvider: String] = [:]
        for provider in ModelProvider.remoteCases {
            if let token = (try? keychain.read(provider)) ?? nil { tokens[provider] = token }
        }
        rows = ProviderRoster.rows(tokens: tokens, activeRemote: remoteProvider, mode: mode, local: onDeviceAvailability)
    }

    private func refreshTokenState() {
        defer { refreshRows() }
        savedRemotes = Set(ModelProvider.remoteCases.filter { keychain.hasToken($0) })
        hasToken = savedRemotes.contains(remoteProvider)
        if let token = (try? keychain.read(remoteProvider)) ?? nil, !token.isEmpty {
            detectedMode = remoteProvider == .anthropic ? AuthMode.detect(fromToken: token) : nil
            statusText = "Key de \(remoteProvider.displayName) guardada."
        } else {
            detectedMode = nil
            statusText = "Sin key de \(remoteProvider.displayName)."
        }
    }

    public func save() {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, tokenTarget.isRemote else { return }
        guard tokenTarget.acceptsTokenFormat(token) else {
            statusText = tokenTarget == .anthropic
                ? "Token no reconocido (esperado sk-ant-api… o sk-ant-oat…)."
                : "Key no reconocida (sin espacios)."
            return
        }
        do {
            try keychain.save(token, for: tokenTarget)
            tokenInput = ""
            refreshTokenState()
            if tokenTarget != remoteProvider {
                statusText = "Key de \(tokenTarget.displayName) guardada; actívala arriba."
            } else {
                onModeChanged?(mode)   // la key del córtex activo cambió: re-cablear
            }
        } catch {
            statusText = "Error al guardar: \(error.localizedDescription)"
        }
    }

    public func refreshCosts() {
        costs = (try? telemetry.summary()) ?? []
        totalCost = (try? telemetry.totalCostUSD()) ?? 0
        monthCost = (try? telemetry.costUSD(since: Self.startOfMonth())) ?? 0
    }

    static func startOfMonth(_ now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: now)?.start ?? now
    }

    /// "ciclo #N · p 0.xx" desde el SelfModel (un solo origen de verdad, FIX C).
    public func refreshMind() async {
        guard let selfModel else { mindSummary = ""; return }
        let cycles = await selfModel.cycles()
        mindSummary = Self.mindLine(cycles: cycles)
        skills?.selfName = await selfModel.name()
    }

    public static func mindLine(cycles: Int) -> String {
        "ciclo #\(cycles) · p \(String(format: "%.2f", Plasticity.value(cycles: cycles)))"
    }

    /// Resumen de la fila "Modelo y costos": provider activo + híbrido + gasto del mes.
    public var modelSummary: String {
        var parts: [String] = [mode == .onDeviceOnly ? ProviderRoster.localName : remoteProvider.displayName]
        if mode == .hybrid { parts.append("híbrido on") }
        parts.append(String(format: "$%.2f este mes", monthCost))
        return parts.joined(separator: " · ")
    }
}

/// Ajustes como HUB (campo batch 3, FIX F; patrón iOS Settings): la raíz es una
/// lista compacta de filas con resumen vivo que pushean sub-pantallas.
public enum SettingsRoute: String, Hashable, CaseIterable, Sendable {
    case account, model, skills, glasses, mind, notifications

    /// Nombre visible de la fila del hub (el mismo que usa AppGuide).
    public var title: String {
        switch self {
        case .account: return "Cuenta"
        case .model: return "Modelo y costos"
        case .skills: return "Skills"
        case .glasses: return "Gafas"
        case .mind: return "Mente"
        case .notifications: return "Notificaciones"
        }
    }
}

public struct SettingsView: View {
    @ObservedObject private var model: SettingsViewModel

    public init(model: SettingsViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack(path: $model.path) {
            ZStack {
                Theme.Colors.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        if let account = model.account {
                            AccountHubRow(account: account)
                            hubDivider
                        }
                        hubRow(.model, title: SettingsRoute.model.title, subtitle: model.modelSummary, glyph: "cpu")
                        if let skills = model.skills {
                            hubDivider
                            SkillsHubRow(skills: skills)
                        }
                        if let glasses = model.glasses {
                            hubDivider
                            GlassesHubRow(glasses: glasses)
                        }
                        hubDivider
                        if let approvals = model.approvals {
                            MindHubRow(summary: model.mindSummary, approvals: approvals)
                        } else {
                            hubRow(.mind, title: SettingsRoute.mind.title, subtitle: model.mindSummary, glyph: "moon")
                        }
                        if let notifications = model.notifications {
                            hubDivider
                            NotificationsHubRow(notifications: notifications)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                    .padding(Theme.Space.screenInset)
                }
            }
            .navigationTitle("Ajustes")
            .navigationDestination(for: SettingsRoute.self) { route in
                destination(route)
            }
        }
        .tint(Theme.Colors.accent)
        .onAppear {
            model.load()
            model.skills?.load()
            Task { await model.refreshMind() }
        }
    }

    private var hubDivider: some View {
        Rectangle().fill(Theme.Colors.border).frame(height: Theme.Stroke.hairline)
            .padding(.leading, 52)
    }

    private func hubRow(_ route: SettingsRoute, title: String, subtitle: String, glyph: String) -> some View {
        NavigationLink(value: route) {
            SettingsHubRowLabel(title: title, subtitle: subtitle, glyph: glyph)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.hub.\(route.rawValue)")
    }

    @ViewBuilder
    private func destination(_ route: SettingsRoute) -> some View {
        switch route {
        case .account:
            if let account = model.account {
                SettingsSubScreen(title: route.title) { AccountSettingsSection(account: account) }
            }
        case .model:
            SettingsSubScreen(title: route.title) {
                ModelSettingsContent(model: model)
            }
        case .skills:
            if let skills = model.skills { SkillsSettingsScreen(model: skills) }
        case .glasses:
            if let glasses = model.glasses {
                SettingsSubScreen(title: route.title) { GlassesSettingsSection(model: glasses) }
            }
        case .mind:
            SettingsSubScreen(title: route.title) { MindSettingsContent(model: model) }
        case .notifications:
            if let notifications = model.notifications {
                SettingsSubScreen(title: route.title) { NotificationsSettingsSection(model: notifications) }
            }
        }
    }
}

/// Fila del hub: glyph SF light (accent en línea), título, resumen vivo, chevron.
struct SettingsHubRowLabel: View {
    let title: String
    let subtitle: String
    let glyph: String

    var body: some View {
        HStack(spacing: Theme.Space.stack) {
            Image(systemName: glyph)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Type_.body)
                    .foregroundStyle(Theme.Colors.text)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.Type_.meta)
                        .foregroundStyle(Theme.Colors.textFaint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(Theme.Colors.textFaint)
        }
        .frame(minHeight: 56)
        .padding(.horizontal, Theme.Space.cardPad)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct AccountHubRow: View {
    @ObservedObject var account: AccountViewModel
    var body: some View {
        NavigationLink(value: SettingsRoute.account) {
            SettingsHubRowLabel(title: SettingsRoute.account.title, subtitle: subtitle, glyph: "person.crop.circle")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.hub.account")
    }
    private var subtitle: String {
        if let email = account.signedInEmail, email != account.displayLine {
            return "\(account.displayLine) · \(email)"
        }
        return account.displayLine
    }
}

private struct SkillsHubRow: View {
    @ObservedObject var skills: SkillsViewModel
    var body: some View {
        NavigationLink(value: SettingsRoute.skills) {
            SettingsHubRowLabel(title: SettingsRoute.skills.title, subtitle: skills.summaryLine, glyph: "book")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.hub.skills")
    }
}

private struct GlassesHubRow: View {
    @ObservedObject var glasses: GlassesViewModel
    var body: some View {
        NavigationLink(value: SettingsRoute.glasses) {
            SettingsHubRowLabel(title: SettingsRoute.glasses.title, subtitle: glasses.hubSummary, glyph: "eyeglasses")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.hub.glasses")
    }
}

private struct MindHubRow: View {
    let summary: String
    @ObservedObject var approvals: ApprovalsInboxViewModel
    var body: some View {
        NavigationLink(value: SettingsRoute.mind) {
            SettingsHubRowLabel(title: SettingsRoute.mind.title, subtitle: subtitle, glyph: "moon")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.hub.mind")
    }
    private var subtitle: String {
        let count = approvals.badgeCount
        guard count > 0 else { return summary }
        return "\(count) por aprobar · \(summary)"
    }
}

private struct NotificationsHubRow: View {
    @ObservedObject var notifications: NotificationsSettingsModel
    var body: some View {
        NavigationLink(value: SettingsRoute.notifications) {
            SettingsHubRowLabel(title: SettingsRoute.notifications.title, subtitle: notifications.hubSummary, glyph: "bell")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.hub.notifications")
        .task { await notifications.refresh() }
    }
}

/// Sub-pantalla estándar del hub: fondo del tema, scroll y título inline.
struct SettingsSubScreen<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Theme.Colors.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.sectionGap) { content }
                    .padding(Theme.Space.screenInset)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayModeInline()
    }
}

/// Modelo y costos: roster de providers + Híbrido + desglose completo de costos.
struct ModelSettingsContent: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
            modeSection
            costsSection
        }
        .onAppear { model.refreshCosts() }
    }

    /// Sección Modelo (§4.9): UNA fila por provider (radio de activo + estado
    /// inline + acción que expande su key), el modelo local en la misma lista,
    /// el toggle Híbrido debajo y qué corre dónde.
    private var modeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            label("Modelo")
            VStack(spacing: 0) {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    providerRow(row)
                    if index < model.rows.count - 1 {
                        Divider().background(Theme.Colors.border).padding(.leading, Theme.Space.cardPad)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))

            if model.mode != .onDeviceOnly {
                Toggle(isOn: Binding(get: { model.mode == .hybrid }, set: { model.setHybrid($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Híbrido")
                            .font(Theme.Type_.body)
                            .foregroundStyle(Theme.Colors.text)
                        Text(model.blocker(for: .hybrid) ?? "El sueño y los pulsos corren en tu teléfono, gratis.")
                            .font(Theme.Type_.meta)
                            .foregroundStyle(Theme.Colors.textFaint)
                    }
                }
                .tint(Theme.Colors.accent)
                .accessibilityIdentifier("settings.mode.hybrid")
            }

            VStack(spacing: Theme.Space.unit * 2) {
                ForEach(SettingsViewModel.placement(for: model.mode), id: \.what) { row in
                    HStack {
                        Text(row.what)
                            .font(Theme.Type_.secondary)
                            .foregroundStyle(Theme.Colors.textMuted)
                        Spacer()
                        Text(row.backend.label(remote: model.remoteProvider))
                            .font(Theme.Type_.secondary)
                            .foregroundStyle(Theme.Colors.accentText)
                    }
                }
            }
            .padding(.top, Theme.Space.stack)
            if let notice = model.modeNotice {
                Text(notice)
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textMuted)
                    .accessibilityIdentifier("settings.mode.notice")
            }
        }
    }

    private func providerRow(_ row: ProviderRow) -> some View {
        let id = "settings.provider.\(row.provider.rawValue)"
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Theme.Space.stack) {
                Button {
                    model.activate(row.provider)
                } label: {
                    HStack(spacing: Theme.Space.stack) {
                        Image(systemName: row.isActive ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(row.isActive ? Theme.Colors.accent
                                             : (row.selectable ? Theme.Colors.textMuted : Theme.Colors.border))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.provider.isRemote ? row.provider.displayName : "📱 " + ProviderRoster.localName)
                                .font(Theme.Type_.body)
                                .foregroundStyle(row.selectable ? Theme.Colors.text : Theme.Colors.textFaint)
                            Text(row.status)
                                .font(Theme.Type_.meta)
                                .foregroundStyle(row.isReady ? Theme.Colors.accentText : Theme.Colors.textFaint)
                                .accessibilityIdentifier("\(id).status")
                            if let detail = row.detail {
                                Text(detail)
                                    .font(Theme.Type_.meta)
                                    .foregroundStyle(Theme.Colors.textFaint)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(id).radio")
                .accessibilityAddTraits(row.isActive ? .isSelected : [])
                if let action = row.actionTitle {
                    Button(model.editing == row.provider ? "Cancelar" : action) {
                        if model.editing == row.provider { model.cancelEditing() } else { model.beginEditing(row.provider) }
                    }
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.accentText)
                    .frame(minHeight: Theme.minHitTarget)
                    .accessibilityIdentifier("\(id).action")
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, Theme.Space.cardPad)
            if model.editing == row.provider {
                ProviderKeyEditor(model: model, row: row)
                    .padding(.horizontal, Theme.Space.cardPad)
                    .padding(.bottom, Theme.Space.stack)
            }
        }
    }

    private var costsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            HStack {
                label("Costos")
                Spacer()
                Text(String(format: "$%.4f", model.totalCost))
                    .font(Theme.Type_.tabular(Theme.Type_.cardTitle))
                    .foregroundStyle(Theme.Colors.accentText)
            }
            if let budget = model.monthlyBudgetUSD {
                HStack {
                    Text("Presupuesto mensual")
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.textMuted)
                    Spacer()
                    Text("$\(budget)")
                        .font(Theme.Type_.tabular(Theme.Type_.secondary))
                        .foregroundStyle(Theme.Colors.textMuted)
                }
            }
            if model.costs.isEmpty {
                Text("Sin turnos registrados.")
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textFaint)
            } else {
                ForEach(model.modelCosts) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: Theme.Space.unit / 2) {
                            Text(row.displayName).font(Theme.Type_.secondary).foregroundStyle(Theme.Colors.text)
                            Text(row.breakdown)
                                .font(Theme.Type_.meta).foregroundStyle(Theme.Colors.textFaint)
                        }
                        Spacer()
                        Text(String(format: "$%.4f", row.costUSD))
                            .font(Theme.Type_.tabular(Theme.Type_.secondary))
                            .foregroundStyle(Theme.Colors.textMuted)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.costs.row")
                }
            }
        }
        .padding(.top, Theme.Space.stack)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.Type_.label)
            .textCase(.uppercase)
            .kerning(0.66)
            .foregroundStyle(Theme.Colors.textMuted)
    }
}

/// Mente: Simular una noche, Repetir onboarding y sus footers.
struct MindSettingsContent: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
            if let approvals = model.approvals {
                ApprovalsSection(model: approvals)
            }
            mindSection
        }
    }

    /// Sección Mente: repetir el onboarding (sin borrar memoria).
    private var mindSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            label("Mente")
            VStack(spacing: 0) {
                if model.nightSimulator != nil {
                    Button {
                        Task { await model.simulateNight() }
                    } label: {
                        HStack {
                            Text("Simular una noche")
                                .font(Theme.Type_.body)
                                .foregroundStyle(model.simulatingNight ? Theme.Colors.textFaint : Theme.Colors.accentText)
                            Spacer()
                            if model.simulatingNight {
                                ProgressView().controlSize(.small).tint(Theme.Colors.accent)
                            } else {
                                Image(systemName: "moon")
                                    .font(.system(size: 12, weight: .light))
                                    .foregroundStyle(Theme.Colors.textFaint)
                            }
                        }
                        .frame(height: 48)
                        .padding(.horizontal, Theme.Space.cardPad)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.simulatingNight)
                    .accessibilityIdentifier("settings.simulateNight")
                    Divider().background(Theme.Colors.border)
                }
                Button {
                    model.replayOnboarding()
                } label: {
                    HStack {
                        Text("Repetir onboarding")
                            .font(Theme.Type_.body)
                            .foregroundStyle(Theme.Colors.accentText)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .light))
                            .foregroundStyle(Theme.Colors.textFaint)
                    }
                    .frame(height: 48)
                    .padding(.horizontal, Theme.Space.cardPad)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.replayOnboarding")
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
            if let summary = model.nightSummary {
                Text(summary)
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.accentText)
                    .accessibilityIdentifier("settings.simulateNight.summary")
            }
            Text("Re-corre el flujo sin borrar memoria; la identidad solo se re-siembra si lo confirmas.")
                .font(Theme.Type_.meta)
                .foregroundStyle(Theme.Colors.textFaint)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.Type_.label)
            .textCase(.uppercase)
            .kerning(0.66)
            .foregroundStyle(Theme.Colors.textMuted)
    }
}

/// Campo de key expandido INLINE bajo su fila: placeholder por provider,
/// Guardar (valida como el onboarding) y Borrar con confirmación.
struct ProviderKeyEditor: View {
    @ObservedObject var model: SettingsViewModel
    let row: ProviderRow
    @State private var confirmDelete = false

    var body: some View {
        let id = "settings.provider.\(row.provider.rawValue)"
        VStack(alignment: .leading, spacing: 8) {
            SecureField(row.provider.tokenPlaceholder, text: $model.keyInput)
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.text)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .padding(Theme.Space.cardPad)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                .onSubmit { Task { await model.saveKey() } }
                .accessibilityIdentifier("\(id).field")
            if let error = model.keyError {
                Text(error)
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textMuted)
                    .accessibilityIdentifier("\(id).error")
            }
            HStack {
                if row.hasKey {
                    Button("Borrar key") { confirmDelete = true }
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.textMuted)
                        .accessibilityIdentifier("\(id).delete")
                }
                Spacer()
                if model.checkingKey { ProgressView().controlSize(.small).tint(Theme.Colors.accent) }
                Button("Guardar") { Task { await model.saveKey() } }
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.accentText)
                    .frame(minHeight: Theme.minHitTarget)
                    .disabled(model.keyInput.trimmingCharacters(in: .whitespaces).isEmpty || model.checkingKey)
                    .accessibilityIdentifier("\(id).save")
            }
        }
        .confirmationDialog("¿Borrar la key de \(row.provider.displayName)?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Borrar", role: .destructive) { model.deleteKey(row.provider) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(row.isActive ? "Es el modelo activo: la selección pasa al siguiente con key o al local." : "Se quita del Keychain de este teléfono.")
        }
    }
}
extension View {
    /// Título inline en iOS (no existe en macOS: el package compila en ambos).
    @ViewBuilder
    func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
#endif
