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
    /// El shell abre los ajustes de notificaciones de iOS (UIApplication).
    public var openSystemSettings: (() -> Void)?
    /// "N programados" → la tab Recordatorios (la cablea el shell).
    public var openList: (() -> Void)?
    /// Re-sincroniza lo programado al prender/apagar los avisos.
    public var onEnabledChanged: (@Sendable () async -> Void)?

    public init(scheduler: any LocalNotificationScheduler, reminders: AnimaReminderStore?,
                preference: ProactivePreference? = nil) {
        self.scheduler = scheduler
        self.reminders = reminders
        self.preference = preference
        enabled = preference?.isEnabled ?? true
    }

    public func refresh() async {
        status = await scheduler.authorizationStatus()
        scheduledCount = await reminders?.scheduledCount() ?? 0
        enabled = preference?.isEnabled ?? true
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
                    VStack(alignment: .leading, spacing: 2) {
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
                        get: { model.enabled && model.status != .denied },
                        set: { on in Task { await model.setEnabled(on) } }))
                        .labelsHidden()
                        .tint(Theme.Colors.accent)
                        .disabled(model.status != .granted)
                        .accessibilityIdentifier("settings.notifications.toggle")
                }
                .padding(.vertical, 10)
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
                        HStack(spacing: 4) {
                            Text(NotificationsSettingsModel.countLabel(model.scheduledCount))
                                .accessibilityIdentifier("settings.notifications.count")
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .light))
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
                    .font(.system(size: 13, weight: .light))
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
