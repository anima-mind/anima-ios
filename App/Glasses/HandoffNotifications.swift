// HandoffNotifications.swift — "ver en el teléfono" desde las gafas (doc 05
// §3.2 patrón handoff). El teléfono suele estar en el bolsillo: se publica una
// notificación local con el deep link `anima://chat?turn=…`; al tocarla, iOS
// abre la app y el shell salta al turno (el delegate es AnimaNotifications).
// Verificable solo en device.

import Foundation
import AnimaKit

#if os(iOS)
import UIKit
import UserNotifications

enum HandoffNotifications {
    static let linkKey = ProactiveNotificationIDs.linkKey
    static let categoryPrefix = "handoff-"
    static let reentryText = "Anima sigue aquí — toca para volver a las gafas."

    static func post(_ link: AnimaDeepLink, body: String = "Sigue la conversación en el teléfono.") {
        Task { @MainActor in
            // Con la app al frente el shell ya saltó al turno: sin notificación.
            guard UIApplication.shared.applicationState != .active else { return }
            guard await NotificationPermission.shared.requestIfNeeded() else { return }
            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            content.title = "Anima"
            content.body = body
            content.userInfo = [linkKey: link.url.absoluteString]
            let request = UNNotificationRequest(identifier: categoryPrefix + UUID().uuidString,
                                                content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
#else
enum HandoffNotifications {
    static let reentryText = "Anima sigue aquí — toca para volver a las gafas."
    static func post(_ link: AnimaDeepLink, body: String = "Sigue la conversación en el teléfono.") {}
}
#endif
