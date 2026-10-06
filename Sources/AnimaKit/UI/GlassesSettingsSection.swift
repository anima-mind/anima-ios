// GlassesSettingsSection.swift — la UI del cuerpo-gafas en el teléfono: sección
// Gafas de Ajustes (estado, batería, vincular/desvincular, actualizar la app
// DAT, mostrar en las gafas) y el view model que comparten el paso Gafas del
// onboarding y el Mind sheet. Las gafas son OPCIONALES: sin ellas todo esto
// dice "solo teléfono" y nada bloquea.

#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
    /// Cómo se pintan los iconos en las gafas. Persistido; default auto.
    @Published public private(set) var iconMode: HUDIconMode

    public static let donWakeKey = "glasses.donWake"
    private let defaults: UserDefaults

    /// Últimos eventos de la bitácora de campo (sección Diagnóstico).
    @Published public private(set) var diagnosticEntries: [GlassesDiagnostics.Entry] = []

    /// Versión del Meta Wearables DAT SDK enlazada (pin exacto en App/project.yml).
    public static let sdkVersion = "1.0.0"

    private let body: GlassesBody?
    private let activation: GlassesActivation?
    private let host: (any GlassesToolHost)?
    public let diagnostics: GlassesDiagnostics
    private var observeTask: Task<Void, Never>?
    private var voiceTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?

    public init(body: GlassesBody?, activation: GlassesActivation?, host: (any GlassesToolHost)? = nil,
                defaults: UserDefaults = .standard, diagnostics: GlassesDiagnostics? = nil) {
        self.body = body
        self.activation = activation
        self.host = host
        self.defaults = defaults
        let diagnostics = diagnostics ?? body?.diagnostics ?? .shared
        self.diagnostics = diagnostics
        let donWake = defaults.object(forKey: Self.donWakeKey) as? Bool ?? true
        self.donWake = donWake
        let iconMode = defaults.string(forKey: HUDIconPolicy.modeKey).flatMap(HUDIconMode.init(rawValue:)) ?? .auto
        self.iconMode = iconMode
        HUDIconPolicy.mode = iconMode
        if let activation { Task { await activation.setDonWakeEnabled(donWake) } }
        let diagnosticUpdates = diagnostics.updates()
        diagnosticsTask = Task { [weak self] in
            for await entries in diagnosticUpdates { self?.diagnosticEntries = entries }
        }
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
        diagnosticsTask?.cancel()
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
        guard let body else { notice = "Las gafas no están disponibles en esta build."; return }
        notice = "Abriendo Meta AI en la actualización de la app DAT…"
        Task {
            do { try await body.openDATGlassesAppUpdate() } catch { notice = "No se pudo abrir Meta AI: \(error)" }
        }
    }

    public func openFirmwareUpdate() {
        guard let body else { notice = "Las gafas no están disponibles en esta build."; return }
        notice = "Abriendo Meta AI en la actualización de firmware…"
        Task {
            do { try await body.openFirmwareUpdate() } catch { notice = "No se pudo abrir Meta AI: \(error)" }
        }
    }

    /// Filas del estado (clave, valor) — lo que el SDK 1.0.0 sí expone.
    public var statusRows: [(key: String, value: String, id: String)] {
        var rows: [(String, String, String)] = [("Estado", stateText, "state")]
        if isRegistered {
            rows.append(("Conexión", Self.linkLabel(status.link), "link"))
            rows.append(("Compatibilidad", Self.compatibilityLabel(status.compatibility), "compat"))
            rows.append(("Batería", batteryText, "battery"))
            if let type = status.deviceType { rows.append(("Modelo", type, "model")) }
            if let thermal = status.thermal { rows.append(("Temperatura", thermal, "thermal")) }
        }
        rows.append(("SDK DAT", Self.sdkVersion, "sdk"))
        rows.append(("App DAT / firmware", "el SDK no expone sus versiones", "versions"))
        rows.append(("\u{201C}Hey Meta, start Anima\u{201D}", voiceStatus.label, "voice"))
        return rows
    }

    static func linkLabel(_ link: GlassesLink?) -> String {
        switch link {
        case .connected: return "conectadas"
        case .connecting: return "conectando…"
        case .disconnected: return "desconectadas"
        case nil: return "sin gafas a la vista"
        }
    }

    static func compatibilityLabel(_ compatibility: GlassesCompatibility?) -> String {
        switch compatibility {
        case .compatible: return "compatible"
        case .deviceUpdateRequired: return "actualiza las gafas (firmware / app DAT)"
        case .sdkUpdateRequired: return "la app necesita un SDK más nuevo"
        case .undefined, nil: return "sin confirmar"
        }
    }

    /// El texto que el dueño copia y pega cuando algo falla en hardware.
    public var diagnosticReport: String {
        let header = statusRows.map { "\($0.key): \($0.value)" } + [
            "Sesión: \(status.sessionState?.rawValue ?? "—") · Display: \(status.displayState?.rawValue ?? "—")",
            "Iconos: \(iconMode.rawValue)",
            "Último error: \(status.lastError ?? "—")",
        ]
        return diagnostics.report(header: header)
    }

    public var diagnosticLines: [String] { diagnosticEntries.map(GlassesDiagnostics.line) }

    public func copyDiagnostics() {
        let report = diagnosticReport
        #if canImport(UIKit)
        UIPasteboard.general.string = report
        #endif
        notice = "Diagnóstico copiado (\(diagnosticEntries.count) eventos)."
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
    @State private var confirmUnpair = false
    @State private var showDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
            statusCard
            actions
            maintenance
            icons
            diagnostics
            Text(model.notice ?? "Opcionales: sin gafas, Anima funciona completa en el teléfono.")
                .font(Theme.Type_.meta)
                .foregroundStyle(Theme.Colors.textFaint)
                .accessibilityIdentifier("settings.glasses.notice")
        }
        .confirmationDialog("¿Desvincular las gafas?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Desvincular", role: .destructive) { model.unpair() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Anima deja de usar las gafas hasta que las vuelvas a vincular desde Meta AI.")
        }
    }

    // MARK: Estado

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            label("Gafas")
            VStack(spacing: 0) {
                ForEach(Array(model.statusRows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().background(Theme.Colors.border) }
                    self.row(row.key, row.value, id: row.id)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
        }
    }

    // MARK: Acciones principales

    @ViewBuilder private var actions: some View {
        if model.isRegistered {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                GlassesActionButton(title: "Mostrar en las gafas", systemImage: "eyeglasses", role: .primary,
                                    id: "settings.glasses.show") { model.showOnGlasses() }
                Toggle(isOn: Binding(get: { model.donWake }, set: { model.setDonWake($0) })) {
                    Text("Despertar al ponértelas")
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.textMuted)
                }
                .tint(Theme.Colors.accentText)
                .frame(minHeight: Theme.minHitTarget)
                .accessibilityIdentifier("settings.glasses.donWake")
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                GlassesActionButton(title: "Vincular gafas", systemImage: "eyeglasses", role: .primary,
                                    id: "settings.glasses.pair") { model.pair() }
                Text("Abre Meta AI para aprobar el vínculo y vuelve aquí.")
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textFaint)
            }
        }
    }

    private var maintenance: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            label("Mantenimiento")
            GlassesActionButton(title: model.needsDATUpdate ? "Actualizar app DAT de las gafas · requerida"
                                                            : "Actualizar app DAT de las gafas",
                                systemImage: "arrow.triangle.2.circlepath", role: .secondary,
                                id: "settings.glasses.datUpdate") { model.openDATUpdate() }
            GlassesActionButton(title: "Actualizar firmware", systemImage: "arrow.down.circle", role: .secondary,
                                id: "settings.glasses.firmwareUpdate") { model.openFirmwareUpdate() }
            if model.isRegistered {
                GlassesActionButton(title: "Desvincular", systemImage: "link", role: .destructive,
                                    id: "settings.glasses.unpair") { confirmUnpair = true }
            }
        }
    }

    // MARK: Iconos (diagnóstico de campo)

    private var icons: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            label("Iconos en las gafas")
            Picker("Iconos en las gafas", selection: Binding(get: { model.iconMode }, set: { model.setIconMode($0) })) {
                ForEach(HUDIconMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.glasses.iconMode")
            if model.canProbeIcons {
                GlassesActionButton(title: model.iconProbeLabel, systemImage: "square.grid.2x2", role: .secondary,
                                    id: "settings.glasses.probeIcons") { model.probeIcons() }
                GlassesActionButton(title: "Probar caminos de iconos", systemImage: "rectangle.split.3x1",
                                    role: .secondary, id: "settings.glasses.probeIconPaths") { model.probeIconPaths() }
            } else {
                Text("Las pruebas de iconos se activan con las gafas puestas y conectadas.")
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textFaint)
            }
        }
    }

    // MARK: Diagnóstico

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            Button {
                withAnimation(.easeOut(duration: Theme.Motion.sheet)) { showDiagnostics.toggle() }
            } label: {
                HStack {
                    Text("Diagnóstico (\(model.diagnosticEntries.count))")
                        .font(Theme.Type_.secondary)
                    Spacer()
                    Image(systemName: showDiagnostics ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13))
                }
                .foregroundStyle(Theme.Colors.textMuted)
                .frame(minHeight: Theme.minHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.glasses.diagnostics")
            if showDiagnostics {
                GlassesActionButton(title: "Copiar diagnóstico", systemImage: "doc.on.doc", role: .secondary,
                                    id: "settings.glasses.copyDiagnostics") { model.copyDiagnostics() }
                if model.diagnosticLines.isEmpty {
                    Text("Sin eventos todavía.")
                        .font(Theme.Type_.meta)
                        .foregroundStyle(Theme.Colors.textFaint)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.diagnosticLines.reversed().enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.Colors.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .accessibilityIdentifier("settings.glasses.diagnosticLog")
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

/// Botón del sistema para Ajustes → Gafas: borde (jamás fill), glifo + título,
/// alto ≥ 44. Primario = acento; secundario = borde neutro; destructivo = tono
/// apagado (el sistema no usa rojo: el peso lo lleva la confirmación).
struct GlassesActionButton: View {
    enum Role { case primary, secondary, destructive }

    let title: String
    let systemImage: String
    let role: Role
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: role == .primary ? 18 : 15, weight: .regular))
                Text(title)
                    .font(.system(size: role == .primary ? 16 : 15, weight: role == .primary ? .medium : .regular))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, Theme.Space.cardPad)
            .frame(maxWidth: .infinity, minHeight: role == .primary ? 52 : Theme.minHitTarget)
            .background(role == .primary ? Theme.Colors.tint : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(border, lineWidth: Theme.Stroke.hairline))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private var foreground: Color {
        switch role {
        case .primary: return Theme.Colors.accentText
        case .secondary: return Theme.Colors.text
        case .destructive: return Theme.Colors.textMuted
        }
    }

    private var border: Color {
        switch role {
        case .primary: return Theme.Colors.accent
        case .secondary, .destructive: return Theme.Colors.border
        }
    }
}
#endif
