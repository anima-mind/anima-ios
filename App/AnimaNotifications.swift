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

    /// Variantes con completion handler, NO las `async`: el thunk de la variante
    /// async invoca el handler desde el pool cooperativo y UIKit aborta
    /// (`_performBlockAfterCATransactionCommitSynchronizes:` exige main thread;
    /// crash del tap al push, campo batch 5 #10). Aquí todo corre en MainActor y
    /// el handler se llama en main.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let raw = response.notification.request.content.userInfo[ProactiveNotificationIDs.linkKey] as? String
        let identifier = response.actionIdentifier
        Task { @MainActor in
            await Self.handle(link: raw.flatMap(URL.init(string:)), actionIdentifier: identifier)
            completionHandler()
        }
    }

    /// Tap → deep link directo al AppModel (sin `UIApplication.open` del propio
    /// scheme: en un cold launch la escena aún no existe y el link se difiere al
    /// terminar el cableado). Acción → corre sin abrir la app.
    @MainActor
    static func handle(link: URL?, actionIdentifier: String) async {
        switch ProactiveNotificationAction.from(actionIdentifier: actionIdentifier, link: link) {
        case .open?, nil:
            guard let link else { return }
            AppModel.live.handleOpenURL(link)
        case let action?:
            await AppModel.live.handleNotificationAction(action)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let options = Self.presentationOptions(category: notification.request.content.categoryIdentifier)
        Task { @MainActor in completionHandler(options) }
    }

    static func presentationOptions(category: String) -> UNNotificationPresentationOptions {
        switch category {
        case ProactiveNotificationIDs.reminderCategory, ProactiveNotificationIDs.checkInCategory:
            return [.banner, .sound, .list]
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
