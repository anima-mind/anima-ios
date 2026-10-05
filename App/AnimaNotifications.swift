// AnimaNotifications.swift — el ÚNICO UNUserNotificationCenterDelegate del shell.
// Registra las categorías de Anima (recordatorio, check-in, Intention) con sus
// acciones; las acciones corren en background sin abrir la app y el tap por
// defecto abre el deep link (lo recibe onOpenURL). Con la app al frente,
// recordatorios y check-ins SÍ se muestran (banner + sonido): el dueño quiere
// que ella le avise aunque esté dentro; el resto conserva el default de iOS.

import Foundation
import AnimaKit

#if os(iOS)
import UIKit
import UserNotifications

final class AnimaNotifications: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = AnimaNotifications()

    static func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        center.setNotificationCategories(categories)
    }

    static var categories: Set<UNNotificationCategory> {
        let done = UNNotificationAction(identifier: ProactiveNotificationIDs.reminderDoneAction, title: "Hecho")
        let snooze = UNNotificationAction(identifier: ProactiveNotificationIDs.reminderSnoozeAction, title: "En 1 hora")
        let yes = UNNotificationAction(identifier: ProactiveNotificationIDs.checkInYesAction, title: "Sí, avancé")
        let no = UNNotificationAction(identifier: ProactiveNotificationIDs.checkInNoAction, title: "Hoy no")
        return [
            UNNotificationCategory(identifier: ProactiveNotificationIDs.reminderCategory, actions: [done, snooze],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: ProactiveNotificationIDs.checkInCategory, actions: [yes, no],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: ProactiveNotificationIDs.intentionCategory, actions: [],
                                   intentIdentifiers: []),
        ]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo[ProactiveNotificationIDs.linkKey] as? String
        let link = raw.flatMap(URL.init(string:))
        let identifier = response.actionIdentifier
        switch ProactiveNotificationAction.from(actionIdentifier: identifier, link: link) {
        case .open?, nil:
            guard let link else { return }
            await MainActor.run { UIApplication.shared.open(link) }
        case let action?:
            await AppModel.live.handleNotificationAction(action)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        switch notification.request.content.categoryIdentifier {
        case ProactiveNotificationIDs.reminderCategory, ProactiveNotificationIDs.checkInCategory:
            return [.banner, .sound]
        default:
            return []
        }
    }
}
#else
enum AnimaNotifications {
    static func install() {}
}
#endif
