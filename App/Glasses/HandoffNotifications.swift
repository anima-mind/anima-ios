// HandoffNotifications.swift — "ver en el teléfono" desde las gafas (doc 05
// §3.2 patrón handoff). El teléfono suele estar en el bolsillo: se publica una
// notificación local con el deep link `anima://chat?turn=…`; al tocarla, iOS
// abre la app y el shell salta al turno. Verificable solo en device.

import Foundation
import AnimaKit

#if os(iOS)
import UIKit
import UserNotifications

final class HandoffNotifications: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = HandoffNotifications()
    static let linkKey = "anima.deeplink"
    static let categoryPrefix = "handoff-"

    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    static func post(_ link: AnimaDeepLink) {
        Task { @MainActor in
            // Con la app al frente el shell ya saltó al turno: sin notificación.
            guard UIApplication.shared.applicationState != .active else { return }
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Anima"
            content.body = "Sigue la conversación en el teléfono."
            content.userInfo = [linkKey: link.url.absoluteString]
            let request = UNNotificationRequest(identifier: categoryPrefix + UUID().uuidString,
                                                content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    // Tocar la notificación → abrir el deep link (lo recibe onOpenURL del shell).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let raw = response.notification.request.content.userInfo[Self.linkKey] as? String,
           let url = URL(string: raw) {
            Task { @MainActor in UIApplication.shared.open(url) }
        }
        completionHandler()
    }

    // Con la app al frente se conserva el default de iOS (sin banner).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}
#else
enum HandoffNotifications {
    static func install() {}
    static func post(_ link: AnimaDeepLink) {}
}
#endif
