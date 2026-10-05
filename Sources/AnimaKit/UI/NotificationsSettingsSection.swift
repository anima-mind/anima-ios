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
    private let scheduler: any LocalNotificationScheduler
    private let reminders: AnimaReminderStore?
    /// El shell abre los ajustes de notificaciones de iOS (UIApplication).
    public var openSystemSettings: (() -> Void)?

    public init(scheduler: any LocalNotificationScheduler, reminders: AnimaReminderStore?) {
        self.scheduler = scheduler
        self.reminders = reminders
    }

    public func refresh() async {
        status = await scheduler.authorizationStatus()
        scheduledCount = await reminders?.scheduledCount() ?? 0
    }

    public func requestPermission() async {
        _ = await scheduler.requestAuthorization()
        await refresh()
    }

    public static func statusLabel(_ status: NotificationAuthorization) -> String {
        switch status {
        case .granted: return "Permitidas"
        case .denied: return "Denegadas"
        case .notDetermined: return "Sin decidir"
        }
    }

    /// Resumen de la fila "Notificaciones" del hub: "Permitidas · N programadas" | "Denegadas".
    public var hubSummary: String { Self.hubSummary(status: status, scheduled: scheduledCount) }

    public static func hubSummary(status: NotificationAuthorization, scheduled: Int) -> String {
        status == .granted ? "Permitidas · \(scheduled) programadas" : statusLabel(status)
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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Avisos de Anima")
                        .font(Theme.Type_.body)
                        .foregroundStyle(Theme.Colors.text)
                    Spacer()
                    Text(NotificationsSettingsModel.statusLabel(model.status))
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(model.status == .denied ? Theme.Colors.accentText : Theme.Colors.textMuted)
                        .accessibilityIdentifier("settings.notifications.status")
                }
                Text(NotificationsSettingsModel.countLabel(model.scheduledCount))
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textFaint)
                    .accessibilityIdentifier("settings.notifications.count")
                switch model.status {
                case .denied:
                    Button("Abrir Ajustes de iOS") { model.openSystemSettings?() }
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.accentText)
                        .accessibilityIdentifier("settings.notifications.open")
                case .notDetermined:
                    Button("Permitir avisos") { Task { await model.requestPermission() } }
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.accentText)
                        .accessibilityIdentifier("settings.notifications.request")
                case .granted:
                    EmptyView()
                }
            }
            .padding(Theme.Space.cardPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .task { await model.refresh() }
    }
}
#endif
