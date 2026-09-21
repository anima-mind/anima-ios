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

    private let keychain: KeychainStore
    private let telemetry: Telemetry
    private let onboardingDefaults: OnboardingDefaults
    /// "Repetir onboarding": re-corre el flujo sin borrar memoria (el Birth
    /// re-siembra solo si el dueño confirma). Lo cablea el shell.
    public var onReplayOnboarding: (() -> Void)?

    public init(keychain: KeychainStore, telemetry: Telemetry,
                onboardingDefaults: OnboardingDefaults = OnboardingDefaults()) {
        self.keychain = keychain
        self.telemetry = telemetry
        self.onboardingDefaults = onboardingDefaults
    }

    public func replayOnboarding() {
        onboardingDefaults.markOnboarded(false)
        onReplayOnboarding?()
    }

    public func load() {
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
                    tokenSection
                    costsSection
                    mindSection
                }
                .padding(Theme.Space.screenInset)
            }
        }
        .onAppear { model.load() }
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
