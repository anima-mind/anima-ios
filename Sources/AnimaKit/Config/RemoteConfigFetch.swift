// RemoteConfigFetch.swift — tope de tiempo para el fetch de Remote Config. Cuando
// el proceso nace por una acción de notificación ("Hecho", "En 1 hora") iOS da
// pocos segundos al handler: se arranca con los defaults bundled (o lo último
// activado) y el fetch remoto tiene ≤ 3 s; si no llega, sigue en segundo plano
// y lo usa el próximo arranque (el snapshot de la sesión ya quedó congelado).

import Foundation

public enum RemoteConfigFetch {
    /// Presupuesto del fetch cuando el proceso nace por una acción de notificación.
    public static let notificationActionTimeout: TimeInterval = 3

    /// Corre `fetch` y espera como mucho `timeout` (nil = sin tope). Devuelve
    /// true si terminó a tiempo; si no, el fetch sigue sin bloquear a nadie.
    public static func run(timeout: TimeInterval?, _ fetch: @escaping @Sendable () async -> Void) async -> Bool {
        guard let timeout else {
            await fetch()
            return true
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                if once.claim() { continuation.resume(returning: false) }
            }
            Task {
                await fetch()
                if once.claim() {
                    timer.cancel()
                    continuation.resume(returning: true)
                }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
