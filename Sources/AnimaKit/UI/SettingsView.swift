// SettingsView.swift — token → KeychainStore, muestra el AuthMode detectado y la
// vista de costos reales desde Telemetry (§6, §7). Dark-only, tokens de Theme.

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var tokenInput: String = ""
    @Published public var detectedMode: AuthMode?
    @Published public var statusText: String = ""
    @Published public var costs: [Telemetry.CostRow] = []
    @Published public var totalCost: Double = 0
    @Published public var monthlyBudgetUSD: Int?
    // Modo de operación (§4.9): cambia entre los 3 sin re-onboarding.
    @Published public private(set) var mode: OperatingMode
    @Published public private(set) var onDeviceAvailability: OnDeviceAvailability
    @Published public private(set) var hasToken: Bool = false
    @Published public var modeNotice: String?

    private let keychain: KeychainStore
    private let telemetry: Telemetry
    private let onboardingDefaults: OnboardingDefaults
    /// "Repetir onboarding": re-corre el flujo sin borrar memoria (el Birth
    /// re-siembra solo si el dueño confirma). Lo cablea el shell.
    public var onReplayOnboarding: (() -> Void)?
    /// Sección Cuenta (Sign in with Apple); la inyecta el shell.
    public var account: AccountViewModel?
    /// El shell re-cablea el harness con el nuevo modo (sin re-onboarding).
    public var onModeChanged: ((OperatingMode) -> Void)?
    private let availabilityProbe: () -> OnDeviceAvailability

    public init(keychain: KeychainStore, telemetry: Telemetry,
                onboardingDefaults: OnboardingDefaults = OnboardingDefaults(),
                availability: @escaping () -> OnDeviceAvailability = { OnDeviceAvailability.current() }) {
        self.keychain = keychain
        self.telemetry = telemetry
        self.onboardingDefaults = onboardingDefaults
        self.availabilityProbe = availability
        self.mode = onboardingDefaults.modeStore.mode
        self.onDeviceAvailability = availability()
    }

    // MARK: Modo

    /// Si el modo se puede elegir ahora; si no, el porqué.
    public func blocker(for mode: OperatingMode) -> String? {
        if mode.requiresOnDevice, let reason = onDeviceAvailability.reason {
            return reason
        }
        if mode.requiresToken, !hasToken {
            return "Requiere tu API key o token de Anthropic (abajo)."
        }
        return nil
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

    public func replayOnboarding() {
        onboardingDefaults.markOnboarded(false)
        onReplayOnboarding?()
    }

    public func load() {
        mode = onboardingDefaults.modeStore.mode
        refreshAvailability()
        hasToken = ((try? keychain.read()) ?? "").isEmpty == false
        if let token = try? keychain.read(), !token.isEmpty {
            detectedMode = AuthMode.detect(fromToken: token)
            statusText = "Token guardado."
        } else {
            statusText = "Sin token."
        }
        monthlyBudgetUSD = onboardingDefaults.monthlyBudgetUSD
        refreshCosts()
    }

    public func save() {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        detectedMode = AuthMode.detect(fromToken: token)
        guard detectedMode != nil else {
            statusText = "Token no reconocido (esperado sk-ant-api… o sk-ant-oat…)."
            return
        }
        do {
            try keychain.save(token)
            hasToken = true
            tokenInput = ""
            statusText = "Token guardado."
        } catch {
            statusText = "Error al guardar: \(error.localizedDescription)"
        }
    }

    public func refreshCosts() {
        costs = (try? telemetry.summary()) ?? []
        totalCost = (try? telemetry.totalCostUSD()) ?? 0
    }
}

public struct SettingsView: View {
    @ObservedObject private var model: SettingsViewModel

    public init(model: SettingsViewModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            Theme.Colors.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
                    if let account = model.account {
                        AccountSettingsSection(account: account)
                    }
                    modeSection
                    tokenSection
                    costsSection
                    mindSection
                }
                .padding(Theme.Space.screenInset)
            }
        }
        .onAppear { model.load() }
    }

    /// Sección Modo (§4.9): los 3 modos, la disponibilidad actual y qué corre dónde.
    private var modeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            label("Modo")
            VStack(spacing: 0) {
                ForEach(Array(OperatingMode.allCases.enumerated()), id: \.element) { index, mode in
                    let selected = model.mode == mode
                    let blocker = model.blocker(for: mode)
                    Button {
                        model.select(mode)
                    } label: {
                        HStack(alignment: .top, spacing: Theme.Space.stack) {
                            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 18, weight: .light))
                                .foregroundStyle(selected ? Theme.Colors.accent : Theme.Colors.textFaint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.title)
                                    .font(Theme.Type_.body)
                                    .foregroundStyle(blocker == nil ? Theme.Colors.text : Theme.Colors.textFaint)
                                Text(blocker ?? mode.summary)
                                    .font(Theme.Type_.meta)
                                    .foregroundStyle(Theme.Colors.textFaint)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, Theme.Space.cardPad)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.mode.\(mode.rawValue)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    if index < OperatingMode.allCases.count - 1 {
                        Divider().background(Theme.Colors.border).padding(.leading, Theme.Space.cardPad)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))

            ForEach(SettingsViewModel.placement(for: model.mode), id: \.what) { row in
                HStack {
                    Text(row.what)
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.textMuted)
                    Spacer()
                    Text(row.backend.label)
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.accentText)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: model.onDeviceAvailability.isAvailable ? "iphone" : "iphone.slash")
                    .font(.system(size: 12, weight: .light))
                Text("Modelo local: " + model.onDeviceAvailability.label)
            }
            .font(Theme.Type_.meta)
            .foregroundStyle(Theme.Colors.textFaint)
            if let notice = model.modeNotice {
                Text(notice)
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textMuted)
                    .accessibilityIdentifier("settings.mode.notice")
            }
        }
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            label("Token del provider")
            SecureField("sk-ant-…", text: $model.tokenInput)
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.text)
                .padding(Theme.Space.cardPad)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline)
                )
            HStack {
                Button("Guardar") { model.save() }
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.accent)
                Spacer()
                if let mode = model.detectedMode {
                    Text("Auth: \(mode.rawValue)")
                        .font(Theme.Type_.meta)
                        .foregroundStyle(Theme.Colors.textMuted)
                }
            }
            Text(model.statusText)
                .font(Theme.Type_.meta)
                .foregroundStyle(Theme.Colors.textFaint)
        }
    }

    /// Sección Mente: repetir el onboarding (sin borrar memoria).
    private var mindSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            label("Mente")
            VStack(spacing: 0) {
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
            Text("Re-corre el flujo sin borrar memoria; la identidad solo se re-siembra si lo confirmas.")
                .font(Theme.Type_.meta)
                .foregroundStyle(Theme.Colors.textFaint)
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
                ForEach(model.costs, id: \.model) { row in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.model).font(Theme.Type_.secondary).foregroundStyle(Theme.Colors.text)
                            Text("\(row.turnClass) · \(row.turns) turnos")
                                .font(Theme.Type_.meta).foregroundStyle(Theme.Colors.textFaint)
                        }
                        Spacer()
                        Text(String(format: "$%.4f", row.costUSD))
                            .font(Theme.Type_.tabular(Theme.Type_.secondary))
                            .foregroundStyle(Theme.Colors.textMuted)
                    }
                    .padding(.vertical, 4)
                }
            }
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
#endif
