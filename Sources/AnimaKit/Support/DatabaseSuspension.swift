// DatabaseSuspension.swift — 0xdead10cc: la base vive en el contenedor del App
// Group y iOS mata a la app suspendida que retiene un lock de SQLite ahí. GRDB
// (observesSuspensionNotifications) suelta los locks y rechaza nuevos al recibir
// `Database.suspendNotification`. Esto decide CUÁNDO: la base está despierta
// mientras haya un dueño (primer plano, un BGTask, una acción de notificación o
// de widget, el vaciado al ir a background) y se suspende al quedar sin dueños o
// cuando iOS avisa que se acaba el tiempo (expirationHandler).

import Foundation
import GRDB

public final class DatabaseSuspension: @unchecked Sendable {
    public static let shared = DatabaseSuspension()

    private let lock = NSLock()
    private let post: @Sendable (Notification.Name) -> Void
    private var holds = 0
    private var foreground = false
    private var suspended = false

    public init(post: @escaping @Sendable (Notification.Name) -> Void = {
        NotificationCenter.default.post(name: $0, object: nil)
    }) {
        self.post = post
    }

    public var isSuspended: Bool { lock.withLock { suspended } }

    /// Escena activa o inactiva (no background): la base despierta.
    public func enterForeground() {
        let notify = lock.withLock { () -> Notification.Name? in
            if !foreground {
                foreground = true
                holds += 1
            }
            return wake()
        }
        notify.map(post)
    }

    /// Escena a background, SÍNCRONO en el onChange (si fuera en un Task, un
    /// .inactive/.active que llegue antes quedaría en no-op y la base terminaría
    /// suspendida con la app abierta). Suelta el hold de la escena y toma uno
    /// para el vaciado (snapshot de widgets…), que quien llama cierra con `end()`.
    public func enterBackground() {
        let notify = lock.withLock { () -> Notification.Name? in
            holds += 1
            if foreground {
                foreground = false
                holds -= 1
            }
            return wake()
        }
        notify.map(post)
    }

    /// Un trabajo que necesita la base (BGTask, acción de notificación/widget).
    public func begin() {
        let notify = lock.withLock { () -> Notification.Name? in
            holds += 1
            return wake()
        }
        notify.map(post)
    }

    public func end() {
        let notify = lock.withLock { () -> Notification.Name? in
            holds = max(0, holds - 1)
            guard holds == 0, !suspended else { return nil }
            suspended = true
            return Database.suspendNotification
        }
        notify.map(post)
    }

    /// `begin` … `end` alrededor de `work`.
    public func awake<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        begin()
        let result = await work()
        end()
        return result
    }

    /// iOS está por suspender la app (expirationHandler): suelta los locks YA,
    /// aunque quede trabajo en curso (sus escrituras fallan y se reintentan). Con
    /// la escena en primer plano la app no se suspende: no hace nada (el trabajo
    /// que expiró suelta su hold con su `end()`).
    public func expire() {
        let notify = lock.withLock { () -> Notification.Name? in
            guard !foreground, !suspended else { return nil }
            suspended = true
            return Database.suspendNotification
        }
        notify.map(post)
    }

    private func wake() -> Notification.Name? {
        guard suspended else { return nil }
        suspended = false
        return Database.resumeNotification
    }
}
