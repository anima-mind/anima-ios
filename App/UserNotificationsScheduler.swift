// UserNotificationsScheduler.swift — adaptador real de LocalNotificationScheduler
// sobre UNUserNotificationCenter. La lógica (qué, cuándo, ids, tope 64) vive en
// AnimaKit (ProactiveScheduler); aquí solo se traduce. Verificable en device.

import Foundation
import AnimaKit

#if os(iOS)
import UserNotifications

struct UserNotificationsScheduler: LocalNotificationScheduler {
    func authorizationStatus() async -> NotificationAuthorization {
        await NotificationPermission.shared.status()
    }

    func requestAuthorization() async -> Bool {
        await NotificationPermission.shared.requestIfNeeded()
    }

    func schedule(_ request: LocalNotificationRequest) async {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.categoryIdentifier = request.categoryId
        content.userInfo = request.userInfo
        let trigger: UNNotificationTrigger?
        switch request.trigger {
        case .immediate:
            trigger = nil
        case .at(let date):
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        case .calendar(let components, let repeats):
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
        }
        let unRequest = UNNotificationRequest(identifier: request.id, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(unRequest)
    }

    func cancel(ids: [String]) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    func pendingIds() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
    }
}

/// Un solo punto de permiso de notificaciones (`.alert, .sound, .badge`), pedido
/// una vez: la primera vez que Anima tiene algo que entregar.
actor NotificationPermission {
    static let shared = NotificationPermission()

    func status() async -> NotificationAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .granted
        }
    }

    func requestIfNeeded() async -> Bool {
        switch await status() {
        case .granted: return true
        case .denied: return false
        case .notDetermined:
            let options: UNAuthorizationOptions = [.alert, .sound, .badge]
            return (try? await UNUserNotificationCenter.current().requestAuthorization(options: options)) ?? false
        }
    }
}
#else
struct UserNotificationsScheduler: LocalNotificationScheduler {
    func authorizationStatus() async -> NotificationAuthorization { .denied }
    func requestAuthorization() async -> Bool { false }
    func schedule(_ request: LocalNotificationRequest) async {}
    func cancel(ids: [String]) async {}
    func pendingIds() async -> [String] { [] }
}
#endif
