// GlassesSettingsSection.swift — la UI del cuerpo-gafas en el teléfono: sección
// Gafas de Ajustes (estado, batería, vincular/desvincular, actualizar la app
// DAT, mostrar en las gafas) y el view model que comparten el paso Gafas del
// onboarding y el Mind sheet. Las gafas son OPCIONALES: sin ellas todo esto
// dice "solo teléfono" y nada bloquea.

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class GlassesViewModel: ObservableObject {
    @Published public private(set) var status = GlassesStatus()
    @Published public var notice: String?
    /// "Hey Meta, start Anima": estado del stream de voice invocations.
    @Published public private(set) var voiceStatus: VoiceInvocationsStatus = .unavailable

    /// Próxima card de "Probar iconos" (diagnóstico de campo del catálogo).
    @Published public private(set) var iconProbeIndex = 0
    /// "Despertar al ponértelas" (don-wake, DAT 1.0). Persistido; default sí.
    @Published public private(set) var donWake: Bool
    /// Cómo se pintan los iconos en las gafas (campo batch 6). Persistido; default auto.
    @Published public private(set) var iconMode: HUDIconMode

    public static let donWakeKey = "glasses.donWake"
    private let defaults: UserDefaults

    private let body: GlassesBody?
    private let activation: GlassesActivation?
    private let host: (any GlassesToolHost)?
    private var observeTask: Task<Void, Never>?
    private var voiceTask: Task<Void, Never>?

    public init(body: GlassesBody?, activation: GlassesActivation?, host: (any GlassesToolHost)? = nil,
                defaults: UserDefaults = .standard) {
        self.body = body
        self.activation = activation
        self.host = host
        self.defaults = defaults
        let donWake = defaults.object(forKey: Self.donWakeKey) as? Bool ?? true
        self.donWake = donWake
        let iconMode = defaults.string(forKey: HUDIconPolicy.modeKey).flatMap(HUDIconMode.init(rawValue:)) ?? .auto
        self.iconMode = iconMode
        HUDIconPolicy.mode = iconMode
        if let activation { Task { await activation.setDonWakeEnabled(donWake) } }
        guard let body else { return }
        observeTask = Task { [weak self] in
            for await status in await body.statusUpdates() {
                self?.status = status
            }
        }
    }

    deinit {
        observeTask?.cancel()
        voiceTask?.cancel()
    }

    public func observeVoiceInvocations(_ orchestrator: VoiceInvocationOrchestrator) {
        voiceTask?.cancel()
        let updates = orchestrator.statusUpdates()
        voiceTask = Task { [weak self] in
            for await status in updates { self?.voiceStatus = status }
        }
    }

    public var isRegistered: Bool { status.isRegistered }
    public var bodyLabel: String { status.bodyLabel }

    /// Texto de estado para Ajustes.
    public var stateText: String {
        if !status.configured { return "Sin configurar (falta MetaAppID del portal Wearables)." }
        switch status.registration {
        case .registered: break
        case .registering: return "Vinculando… aprueba en la app Meta AI."
        case .available, .unavailable: return "No vinculadas."
        }
        let name = status.deviceName.map { " · \($0)" } ?? ""
        return status.bodyLabel.prefix(1).uppercased() + status.bodyLabel.dropFirst() + name
    }

    /// Resumen de la fila "Gafas" del hub: "No vinculadas" | "Conectadas · 43%".
    public var hubSummary: String {
        guard status.configured else { return "Sin configurar" }
        switch status.registration {
        case .registering: return "Vinculando…"
        case .available, .unavailable: return "No vinculadas"
        case .registered: break
        }
        let label = status.bodyLabel.prefix(1).uppercased() + status.bodyLabel.dropFirst()
        return status.batteryPercent.map { "\(label) · \($0)%" } ?? label
    }

    public var batteryText: String {
        status.batteryPercent.map { "\($0)%" } ?? "no la reporta el SDK"
    }

    public var needsDATUpdate: Bool {
        status.body == .incompatible || status.body == .ailing(.updateRequired)
    }

    public func pair() {
        guard let body else { notice = "Las gafas no están disponibles en esta build."; return }
        notice = "Abriendo Meta AI para aprobar el vínculo…"
        Task {
            do { try await body.register() } catch { notice = "No se pudo vincular: \(error)" }
        }
    }

    public func unpair() {
        guard let body else { return }
        Task {
            do { try await body.unregister(); notice = "Gafas desvinculadas." }
            catch { notice = "No se pudo desvincular: \(error)" }
        }
    }

    public func openDATUpdate() {
        guard let body else { return }
        Task {
            do { try await body.openDATGlassesAppUpdate() } catch { notice = "No se pudo abrir Meta AI: \(error)" }
        }
    }

    public func setDonWake(_ enabled: Bool) {
        donWake = enabled
        defaults.set(enabled, forKey: Self.donWakeKey)
        guard let activation else { return }
        Task { await activation.setDonWakeEnabled(enabled) }
    }

    public func showOnGlasses() {
        guard let activation else { return }
        Task { await activation.userRequested() }
    }

    public func setIconMode(_ mode: HUDIconMode) {
        iconMode = mode
        HUDIconPolicy.mode = mode
        defaults.set(mode.rawValue, forKey: HUDIconPolicy.modeKey)
    }

    /// Proyecta la card que pinta 4 iconos por los 3 caminos (M / I / T).
    public func probeIconPaths() {
        guard let host else { return }
        Task {
            if await host.project(HUDIconProbe.pathsCard()) {
                notice = "Caminos en las gafas: anota por icono cuál se ve (M=Meta, I=Imagen, T=Texto)."
            } else {
                notice = "No se pudo proyectar: termina la conversación en las gafas y reintenta."
            }
        }
    }

    /// "Probar iconos" solo con las gafas activas y la superficie HUD cableada.
    public var canProbeIcons: Bool { status.isActive && host != nil }

    public var iconProbeLabel: String {
        "Probar iconos (\(iconProbeIndex + 1)/\(HUDIconProbe.cardCount))"
    }

    /// Proyecta la siguiente card de iconos por el camino normal (card del agente).
    public func probeIcons() {
        guard let host else { return }
        let index = iconProbeIndex
        Task {
            let shown = await host.project(HUDIconProbe.card(index))
            if shown {
                iconProbeIndex = (index + 1) % HUDIconProbe.cardCount
                notice = "Card \(index + 1)/\(HUDIconProbe.cardCount) en las gafas: anota qué nombres salen como sol."
            } else {
                notice = "No se pudo proyectar: termina la conversación en las gafas y reintenta."
            }
        }
    }
}

struct GlassesSettingsSection: View {
    @ObservedObject var model: GlassesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            Text("Gafas")
                .font(Theme.Type_.label)
                .textCase(.uppercase)
                .kerning(0.66)
                .foregroundStyle(Theme.Colors.textMuted)
            VStack(spacing: 0) {
                row("Estado", model.stateText, id: "state")
                Divider().background(Theme.Colors.border)
                row("\u{201C}Hey Meta, start Anima\u{201D}", model.voiceStatus.label, id: "voice")
                if model.isRegistered {
                    Divider().background(Theme.Colors.border)
                    row("Batería", model.batteryText, id: "battery")
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
            if model.isRegistered {
                Toggle(isOn: Binding(get: { model.donWake }, set: { model.setDonWake($0) })) {
                    Text("Despertar al ponértelas")
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.textMuted)
                }
                .tint(Theme.Colors.accentText)
                .frame(minHeight: Theme.minHitTarget)
                .accessibilityIdentifier("settings.glasses.donWake")
            }
            HStack(spacing: Theme.Space.stack) {
                if model.isRegistered {
                    Button("Mostrar en las gafas") { model.showOnGlasses() }
                        .foregroundStyle(Theme.Colors.accentText)
                        .accessibilityIdentifier("settings.glasses.show")
                    Spacer()
                    Button("Desvincular") { model.unpair() }
                        .foregroundStyle(Theme.Colors.textMuted)
                        .accessibilityIdentifier("settings.glasses.unpair")
                } else {
                    Button("Vincular gafas") { model.pair() }
                        .foregroundStyle(Theme.Colors.accentText)
                        .accessibilityIdentifier("settings.glasses.pair")
                    Spacer()
                }
            }
            .font(Theme.Type_.secondary)
            .frame(minHeight: Theme.minHitTarget)
            if model.canProbeIcons {
                Button(model.iconProbeLabel) { model.probeIcons() }
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.accentText)
                    .frame(minHeight: Theme.minHitTarget)
                    .accessibilityIdentifier("settings.glasses.probeIcons")
                Button("Probar caminos de iconos") { model.probeIconPaths() }
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.accentText)
                    .frame(minHeight: Theme.minHitTarget)
                    .accessibilityIdentifier("settings.glasses.probeIconPaths")
            }
            Picker("Iconos en las gafas", selection: Binding(get: { model.iconMode }, set: { model.setIconMode($0) })) {
                ForEach(HUDIconMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.glasses.iconMode")
            if model.needsDATUpdate {
                Button("Actualizar la app DAT de las gafas") { model.openDATUpdate() }
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.accentText)
            }
            Text(model.notice ?? "Opcionales: sin gafas, Anima funciona completa en el teléfono.")
                .font(Theme.Type_.meta)
                .foregroundStyle(Theme.Colors.textFaint)
                .accessibilityIdentifier("settings.glasses.notice")
        }
    }

    private func row(_ key: String, _ value: String, id: String) -> some View {
        HStack {
            Text(key)
                .font(Theme.Type_.secondary)
                .foregroundStyle(Theme.Colors.textFaint)
            Spacer()
            Text(value)
                .font(Theme.Type_.secondary)
                .foregroundStyle(Theme.Colors.textMuted)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 40)
        .padding(.horizontal, Theme.Space.cardPad)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.glasses.\(id)")
    }
}
#endif
