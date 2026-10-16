// TalkLaunchGate.swift — "Hablar con Anima" (control, widget, Siri, deep link
// `anima://chat?mic=1`): la intención de abrir con el mic queda PENDIENTE y se
// ejecuta solo con la escena `.active` y el chat cableado, tras un respiro
// para que termine la transición (Centro de control / pantalla bloqueada).
// Campo build 27: el link llegaba con la escena `.inactive` y la captura
// (AVAudioSession + AVAudioEngine) fallaba sin decir nada.

import Foundation

@MainActor
public final class TalkLaunchGate {
    /// Respiro tras pasar a `.active` antes de tocar el audio.
    public static let defaultSettle: Duration = .milliseconds(350)
    /// Un pedido viejo (la app nunca llegó a `.active`) no arranca la escucha después.
    public static let defaultExpiry: TimeInterval = 60
    /// El mismo tap puede llegar dos veces (p. ej. el widget y su deep link en frío).
    public static let defaultCoalesce: TimeInterval = 3

    public private(set) var isActive = false
    public private(set) var isReady = false
    private var requestedAt: Date?
    private var firedAt: Date?
    private var generation = 0

    private let settle: Duration
    private let expiry: TimeInterval
    private let coalesce: TimeInterval
    private let now: () -> Date
    private let sleep: @Sendable (Duration) async -> Void
    private let start: @MainActor () -> Void

    public init(settle: Duration = TalkLaunchGate.defaultSettle,
                expiry: TimeInterval = TalkLaunchGate.defaultExpiry,
                coalesce: TimeInterval = TalkLaunchGate.defaultCoalesce,
                now: @escaping () -> Date = Date.init,
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                start: @escaping @MainActor () -> Void) {
        self.settle = settle
        self.expiry = expiry
        self.coalesce = coalesce
        self.now = now
        self.sleep = sleep
        self.start = start
    }

    /// ¿Hay un "abrir con mic" esperando escena activa + chat?
    public var isPending: Bool {
        guard let requestedAt else { return false }
        return now().timeIntervalSince(requestedAt) < expiry
    }

    /// Pide abrir con el mic. Un duplicado del mismo tap no arranca dos escuchas.
    public func request() {
        let at = now()
        if let firedAt, at.timeIntervalSince(firedAt) < coalesce { return }
        if isPending { return }
        requestedAt = at
        attempt()
    }

    /// scenePhase: solo `.active` deja arrancar; perderlo deja el pedido esperando.
    public func setActive(_ active: Bool) {
        isActive = active
        if active { attempt() } else { generation += 1 }
    }

    /// El chat cableado (phase .ready + chatModel); un re-cableado lo baja y lo sube.
    public func setReady(_ ready: Bool) {
        isReady = ready
        if ready { attempt() } else { generation += 1 }
    }

    /// Lanza tras el respiro si TODO sigue en pie al despertar.
    @discardableResult
    func attempt() -> Task<Void, Never>? {
        guard isActive, isReady, isPending else { return nil }
        generation += 1
        let ticket = generation
        return Task { [weak self, sleep, settle] in
            await sleep(settle)
            self?.fire(ticket)
        }
    }

    private func fire(_ ticket: Int) {
        guard ticket == generation, isActive, isReady, isPending else { return }
        requestedAt = nil
        firedAt = now()
        start()
    }
}
