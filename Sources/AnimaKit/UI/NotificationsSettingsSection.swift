// NotificationsSettingsSection.swift — fila "Notificaciones" de Ajustes: estado
// del permiso (Permitidas / Denegadas → abrir Ajustes de iOS) y cuántos
// recordatorios de Anima hay programados. Es la sub-pantalla de la fila
// "Notificaciones" del hub de Ajustes (settings.hub.notifications).

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class NotificationsSettingsModel: ObservableObject {
    @Published public private(set) var status: NotificationAuthorization = .notDetermined
    @Published public private(set) var scheduledCount = 0
    /// "Avisos de Anima": la preferencia de la app (aparte del permiso del iPhone).
    @Published public private(set) var enabled = true
    private let scheduler: any LocalNotificationScheduler
    private let reminders: AnimaReminderStore?
    private let preference: ProactivePreference?
    private let wake: WakePreference?
    /// "Avisarme cuando despierte" (batch 8 #7): un push al terminar el sueño.
    @Published public private(set) var wakeEnabled = true
    /// Apagarlo cancela el aviso pendiente (lo cablea el shell).
    public var onWakeChanged: (@Sendable (Bool) async -> Void)?
    /// El shell abre los ajustes de notificaciones de iOS (UIApplication).
    public var openSystemSettings: (() -> Void)?
    /// "N programados" → la tab Recordatorios (la cablea el shell).
    public var openList: (() -> Void)?
    /// Re-sincroniza lo programado al prender/apagar los avisos.
    public var onEnabledChanged: (@Sendable () async -> Void)?
    /// "Avisos si no hablamos": una pregunta suya tras N días sin uso.
    private let nudges: ReengagementPreference?
    @Published public private(set) var nudgeEnabled = true
    @Published public private(set) var nudgeDays = ReengagementPreference.defaultDays
    /// Re-programa la cadena al cambiar el toggle o los días (lo cablea el shell).
    public var onNudgeChanged: (@Sendable () async -> Void)?
    /// "Probar en 1 minuto": programa un aviso suelto (true si quedó programado).
    public var onNudgeProbe: (@Sendable () async -> Bool)?
    @Published public private(set) var nudgeProbeScheduled = false

    public init(scheduler: any LocalNotificationScheduler, reminders: AnimaReminderStore?,
                preference: ProactivePreference? = nil, wake: WakePreference? = nil,
                nudges: ReengagementPreference? = nil) {
        self.scheduler = scheduler
        self.reminders = reminders
        self.preference = preference
        self.wake = wake
        self.nudges = nudges
        enabled = preference?.isEnabled ?? true
        wakeEnabled = wake?.isEnabled ?? true
        nudgeEnabled = nudges?.isEnabled ?? true
        nudgeDays = nudges?.days ?? ReengagementPreference.defaultDays
    }

    public func setNudgeEnabled(_ on: Bool) async {
        nudges?.isEnabled = on
        nudgeEnabled = on
        nudgeProbeScheduled = false
        await onNudgeChanged?()
    }

    /// 2, 3 o 5 días.
    public func setNudgeDays(_ days: Int) async {
        guard ReengagementPreference.dayOptions.contains(days) else { return }
        nudges?.days = days
        nudgeDays = days
        await onNudgeChanged?()
    }

    public func probeNudge() async {
        nudgeProbeScheduled = await onNudgeProbe?() ?? false
    }

    /// Respeta el toggle general (y por él, el permiso del iPhone).
    public var nudgeToggleIsOn: Bool { nudgeEnabled && toggleIsOn }
    public var nudgeToggleIsEnabled: Bool { toggleIsOn }

    public static func nudgeDetail(days: Int) -> String {
        "Si pasan \(days) días sin que hablemos, te escribo una pregunta."
    }

    public static func nudgeDaysLabel(_ days: Int) -> String { "\(days) días" }

    public func setWakeEnabled(_ on: Bool) async {
        wake?.isEnabled = on
        wakeEnabled = on
        await onWakeChanged?(on)
    }

    /// Respeta el toggle general: sin avisos de Anima, tampoco el de despertar.
    public var wakeToggleIsOn: Bool { wakeEnabled && toggleIsOn }
    public var wakeToggleIsEnabled: Bool { toggleIsOn }

    public func refresh() async {
        status = await scheduler.authorizationStatus()
        scheduledCount = await reminders?.scheduledCount() ?? 0
        enabled = preference?.isEnabled ?? true
        wakeEnabled = wake?.isEnabled ?? true
        nudgeEnabled = nudges?.isEnabled ?? true
        nudgeDays = nudges?.days ?? ReengagementPreference.defaultDays
    }

    public func requestPermission() async {
        _ = await scheduler.requestAuthorization()
        await refresh()
        await onEnabledChanged?()
    }

    /// OFF: cancela lo programado y no programa nada nuevo (el store queda
    /// intacto). ON: re-sincroniza.
    public func setEnabled(_ on: Bool) async {
        preference?.isEnabled = on
        enabled = on
        await onEnabledChanged?()
        await refresh()
    }

    /// El toggle se ve ON solo si de verdad avisa: preferencia ON y permiso del
    /// iPhone concedido (sin decidir o denegado = OFF y deshabilitado).
    public var toggleIsOn: Bool { enabled && status == .granted }
    public var toggleIsEnabled: Bool { status == .granted }

    public static func statusLabel(_ status: NotificationAuthorization) -> String {
        switch status {
        case .granted: return "Permitidas"
        case .denied: return "Denegadas"
        case .notDetermined: return "Sin decidir"
        }
    }

    /// Segunda línea de la fila: el permiso del sistema y qué pasa con los avisos.
    public static func detail(status: NotificationAuthorization, enabled: Bool) -> String {
        switch status {
        case .denied: return "Permiso del iPhone: denegado. Actívalo en Ajustes del iPhone."
        case .notDetermined: return "Aún no le has dado permiso a Anima para avisarte."
        case .granted: return enabled ? "Permiso del iPhone: permitido." : "Apagados: Anima no te avisará."
        }
    }

    /// Resumen de la fila "Notificaciones" del hub: "Permitidas · N programadas" | "Denegadas".
    public var hubSummary: String { Self.hubSummary(status: status, scheduled: scheduledCount, enabled: enabled) }

    public static func hubSummary(status: NotificationAuthorization, scheduled: Int, enabled: Bool = true) -> String {
        guard status == .granted else { return statusLabel(status) }
        return enabled ? "Permitidas · \(scheduled) programadas" : "Avisos apagados"
    }

    public static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 recordatorio programado" : "\(count) recordatorios programados"
    }
}

public struct NotificationsSettingsSection: View {
    @ObservedObject var model: NotificationsSettingsModel

    public init(model: NotificationsSettingsModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            Text("Notificaciones")
                .font(Theme.Type_.label)
                .textCase(.uppercase)
                .kerning(0.66)
                .foregroundStyle(Theme.Colors.textMuted)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: Theme.Space.stack) {
                    VStack(alignment: .leading, spacing: Theme.Space.unit / 2) {
                        Text("Avisos de Anima")
                            .font(Theme.Type_.body)
                            .foregroundStyle(Theme.Colors.text)
                        Text(NotificationsSettingsModel.detail(status: model.status, enabled: model.enabled))
                            .font(Theme.Type_.meta)
                            .foregroundStyle(model.status == .denied ? Theme.Colors.accentText : Theme.Colors.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.notifications.status")
                    }
                    Spacer(minLength: 0)
                    Toggle("Avisos de Anima", isOn: Binding(
                        get: { model.toggleIsOn },
                        set: { on in Task { await model.setEnabled(on) } }))
                        .labelsHidden()
                        .tint(Theme.Colors.accent)
                        .disabled(!model.toggleIsEnabled)
                        .accessibilityIdentifier("settings.notifications.toggle")
                }
                .padding(.vertical, Theme.Space.unit * 2.5)
                divider
                HStack(alignment: .center, spacing: Theme.Space.stack) {
                    VStack(alignment: .leading, spacing: Theme.Space.unit / 2) {
                        Text("Avisarme cuando despierte")
                            .font(Theme.Type_.body)
                            .foregroundStyle(model.wakeToggleIsEnabled ? Theme.Colors.text : Theme.Colors.textFaint)
                        Text("Un aviso en la mañana cuando termine de dormir y ordenar lo del día anterior.")
                            .font(Theme.Type_.meta)
                            .foregroundStyle(Theme.Colors.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("Avisarme cuando despierte", isOn: Binding(
                        get: { model.wakeToggleIsOn },
                        set: { on in Task { await model.setWakeEnabled(on) } }))
                        .labelsHidden()
                        .tint(Theme.Colors.accent)
                        .disabled(!model.wakeToggleIsEnabled)
                        .accessibilityIdentifier("settings.notifications.wake")
                }
                .padding(.vertical, Theme.Space.unit * 2.5)
                divider
                nudgeRow
                switch model.status {
                case .denied:
                    divider
                    actionButton("Abrir ajustes del iPhone", glyph: "arrow.up.forward.app",
                                 id: "settings.notifications.open") { model.openSystemSettings?() }
                case .notDetermined:
                    divider
                    actionButton("Permitir avisos", glyph: "bell.badge", id: "settings.notifications.request") {
                        Task { await model.requestPermission() }
                    }
                case .granted:
                    EmptyView()
                }
                divider
                if let openList = model.openList {
                    Button(action: openList) {
                        HStack(spacing: Theme.Space.unit) {
                            Text(NotificationsSettingsModel.countLabel(model.scheduledCount))
                                .accessibilityIdentifier("settings.notifications.count")
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(Theme.Type_.meta.weight(.light))
                                .foregroundStyle(Theme.Colors.textFaint)
                        }
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.accentText)
                        .frame(minHeight: Theme.minHitTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.notifications.list")
                } else {
                    Text(NotificationsSettingsModel.countLabel(model.scheduledCount))
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.textFaint)
                        .frame(minHeight: Theme.minHitTarget)
                        .accessibilityIdentifier("settings.notifications.count")
                }
            }
            .padding(.horizontal, Theme.Space.cardPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .task { await model.refresh() }
    }

    /// "Avisos si no hablamos" + cada cuántos días + probarlo.
    private var nudgeRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            HStack(alignment: .center, spacing: Theme.Space.stack) {
                VStack(alignment: .leading, spacing: Theme.Space.unit / 2) {
                    Text("Avisos si no hablamos")
                        .font(Theme.Type_.body)
                        .foregroundStyle(model.nudgeToggleIsEnabled ? Theme.Colors.text : Theme.Colors.textFaint)
                    Text(NotificationsSettingsModel.nudgeDetail(days: model.nudgeDays))
                        .font(Theme.Type_.meta)
                        .foregroundStyle(Theme.Colors.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.notifications.nudge.detail")
                }
                Spacer(minLength: 0)
                Toggle("Avisos si no hablamos", isOn: Binding(
                    get: { model.nudgeToggleIsOn },
                    set: { on in Task { await model.setNudgeEnabled(on) } }))
                    .labelsHidden()
                    .tint(Theme.Colors.accent)
                    .disabled(!model.nudgeToggleIsEnabled)
                    .accessibilityIdentifier("settings.notifications.nudge")
            }
            if model.nudgeToggleIsOn {
                Picker("Cada cuántos días", selection: Binding(
                    get: { model.nudgeDays },
                    set: { days in Task { await model.setNudgeDays(days) } })) {
                    ForEach(ReengagementPreference.dayOptions, id: \.self) { days in
                        Text(NotificationsSettingsModel.nudgeDaysLabel(days)).tag(days)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.notifications.nudge.days")
                Button { Task { await model.probeNudge() } } label: {
                    HStack {
                        Text(model.nudgeProbeScheduled ? "Listo: te escribo en un minuto" : "Probar en 1 minuto")
                        Spacer(minLength: 0)
                        Image(systemName: model.nudgeProbeScheduled ? "checkmark" : "paperplane")
                            .font(Theme.Type_.secondary.weight(.light))
                    }
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.accentText)
                    .frame(minHeight: Theme.minHitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.notifications.nudge.probe")
            }
        }
        .padding(.vertical, Theme.Space.unit * 2.5)
    }

    private var divider: some View {
        Rectangle().fill(Theme.Colors.border).frame(height: Theme.Stroke.hairline)
    }

    private func actionButton(_ title: String, glyph: String, id: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer(minLength: 0)
                Image(systemName: glyph)
                    .font(Theme.Type_.secondary.weight(.light))
            }
            .font(Theme.Type_.secondary)
            .foregroundStyle(Theme.Colors.accentText)
            .frame(minHeight: Theme.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
#endif
