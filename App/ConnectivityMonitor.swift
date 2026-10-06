// ConnectivityMonitor.swift — NWPathMonitor del shell (batch 5b #7): sin red,
// el chat muestra "Sin conexión" y encola lo que iba a un modelo remoto. En
// `--uitest-offline` se fuerza sin red (XCUITest de la pill).

import Foundation
import Network

final class ConnectivityMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "mind.anima.connectivity")

    /// `onChange(offline)` en MainActor; solo cuando cambia.
    func start(onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        if UITestMode.forcesOffline {
            Task { @MainActor in onChange(true) }
            return
        }
        monitor.pathUpdateHandler = { path in
            let offline = path.status != .satisfied
            Task { @MainActor in onChange(offline) }
        }
        monitor.start(queue: queue)
    }
}
