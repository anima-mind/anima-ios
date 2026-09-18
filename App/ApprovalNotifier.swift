// ApprovalNotifier.swift — canal proactivo hacia el dueño (§5.5): una notificación
// local cuando un cambio identitario queda a la espera de su aprobación. La lógica
// vive en AnimaKit (protocol ApprovalNotifier); el uso de UserNotifications es del
// app shell y va tras #if os(iOS). Pendiente de verificación en device real.

import Foundation
import AnimaKit

#if os(iOS)
import UserNotifications

struct UserNotificationApprovalNotifier: ApprovalNotifier {
    func notifyPendingApproval(_ approval: PendingApproval) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = "Anima propone un cambio de identidad"
        content.body = "\(approval.field.rawValue): \(approval.after). Requiere tu aprobación."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "approval-\(approval.id)", content: content, trigger: nil)
        try? await center.add(request)
    }
}
#else
struct UserNotificationApprovalNotifier: ApprovalNotifier {
    func notifyPendingApproval(_ approval: PendingApproval) async {}
}
#endif
