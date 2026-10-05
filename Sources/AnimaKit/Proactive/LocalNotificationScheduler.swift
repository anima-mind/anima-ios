// LocalNotificationScheduler.swift — la frontera con UNUserNotificationCenter.
// Sin backend ni APNs: todo lo proactivo son notificaciones LOCALES (ese es el
// cron de iOS). La lógica (qué programar, ids, tope de 64) vive en AnimaKit
// contra este protocolo; el adaptador real lo pone el app shell.

import Foundation

public enum NotificationAuthorization: Sendable, Equatable {
    case notDetermined, granted, denied
}

/// Identificadores estables: categorías, acciones y prefijos de request.
public enum ProactiveNotificationIDs {
    public static let reminderCategory = "anima.reminder"
    public static let checkInCategory = "anima.checkin"
    public static let intentionCategory = "anima.intention"

    public static let reminderDoneAction = "anima.reminder.done"
    public static let reminderSnoozeAction = "anima.reminder.snooze"
    public static let checkInYesAction = "anima.checkin.yes"
    public static let checkInNoAction = "anima.checkin.no"

    public static let reminderPrefix = "anima-reminder-"
    public static let checkInPrefix = "anima-checkin-"
    public static let intentionPrefix = "anima-intention-"

    /// userInfo: el deep link que abre el shell al tocar la notificación.
    public static let linkKey = "anima.deeplink"

    /// iOS guarda ≤64 pendientes por app; se dejan 4 de holgura (handoff, aprobaciones).
    public static let maxPending = 60

    /// Minutos del "En 1 hora".
    public static let snoozeMinutes = 60
}

public struct LocalNotificationRequest: Sendable, Equatable {
    public enum Trigger: Sendable, Equatable {
        case immediate
        case at(Date)
        /// Repetitiva por componentes (hour/minute[/weekday]) en hora local.
        case calendar(DateComponents, repeats: Bool)
    }

    public var id: String
    public var title: String
    public var body: String
    public var trigger: Trigger
    public var categoryId: String
    public var deepLink: URL?

    public init(id: String, title: String, body: String, trigger: Trigger, categoryId: String, deepLink: URL?) {
        self.id = id
        self.title = title
        self.body = body
        self.trigger = trigger
        self.categoryId = categoryId
        self.deepLink = deepLink
    }

    public var userInfo: [String: String] {
        deepLink.map { [ProactiveNotificationIDs.linkKey: $0.absoluteString] } ?? [:]
    }
}

public protocol LocalNotificationScheduler: Sendable {
    func authorizationStatus() async -> NotificationAuthorization
    /// Pide permiso UNA vez (si ya se decidió, devuelve el estado sin preguntar).
    func requestAuthorization() async -> Bool
    func schedule(_ request: LocalNotificationRequest) async
    func cancel(ids: [String]) async
    func pendingIds() async -> [String]
}

/// Doble determinista (tests, previews y `--uitest`): guarda lo programado.
public final class FakeNotificationScheduler: LocalNotificationScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String: LocalNotificationRequest] = [:]
    private var status: NotificationAuthorization
    private let grantOnRequest: Bool
    private var authorizationRequests = 0

    public init(status: NotificationAuthorization = .notDetermined, grantOnRequest: Bool = true) {
        self.status = status
        self.grantOnRequest = grantOnRequest
    }

    public var scheduled: [String: LocalNotificationRequest] { locked { requests } }
    public var requestCount: Int { locked { authorizationRequests } }

    public func authorizationStatus() async -> NotificationAuthorization { locked { status } }

    public func requestAuthorization() async -> Bool {
        locked {
            if status == .notDetermined {
                authorizationRequests += 1
                status = grantOnRequest ? .granted : .denied
            }
            return status == .granted
        }
    }

    public func schedule(_ request: LocalNotificationRequest) async {
        locked { requests[request.id] = request }
    }

    public func cancel(ids: [String]) async {
        locked { for id in ids { requests[id] = nil } }
    }

    public func pendingIds() async -> [String] { locked { Array(requests.keys).sorted() } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
