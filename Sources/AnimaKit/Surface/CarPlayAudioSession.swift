// CarPlayAudioSession.swift — quién es DUEÑO de la sesión de audio del carro.
// La conversación la toma (`activateConversation`) y la suelta
// (`releaseConversation`); la captura y el TTS reutilizados de las gafas la
// tocan a través del puerto AudioSessionPort, pero SOLO mientras la
// conversación la tiene. Sin esto, una captura cancelada por la desconexión
// del carro llamaba a `releaseCapture` → `activatePlaybackA2DP` DESPUÉS de que
// la conversación soltara la sesión y la re-activaba (.playAndRecord sin
// mezcla) sin que nadie la volviera a soltar: la música no volvía.

import Foundation

/// La sesión de audio real (AVAudioSession en iOS) detrás de un puerto fino.
public protocol AudioSessionControl: Sendable {
    func configure(_ spec: CarPlayAudioSpec) throws
    func setActive(_ active: Bool, notifyOthers: Bool) throws
    /// Ya inactiva: si la categoría quedó sin mezcla (.playAndRecord, .record,
    /// .playback), vuelve a una que mezcla, para que nada de Anima corte el audio de otros.
    func restoreMixable()
}

/// La sesión ya no es de quien quiere usarla (la conversación la soltó): una
/// captura o un TTS rezagados no la re-activan y no suenan.
public struct AudioSessionNotOwned: Error, Equatable {
    public init() {}
}

/// Soltar la sesión es un deber, no un intento: `setActive(false)` falla
/// (`isBusy`) mientras haya I/O en curso — el engine de la captura que aún no
/// para, el sintetizador que termina su buffer — y antes ese error se tragaba
/// con `try?`: la sesión quedaba activa en .playAndRecord sin mezcla y la música
/// del carro no volvía. Ahora la liberación queda PENDIENTE hasta lograrse:
/// reintenta con backoff y otra vez cuando la captura termina su teardown.
public final class CarPlayAudioSessionOwner: CarPlayAudioPort, AudioSessionPort, @unchecked Sendable {
    public static let releaseBackoff: [Duration] = [50, 100, 200, 400, 800, 1600].map { .milliseconds($0) }

    public let spec: CarPlayAudioSpec
    private let control: any AudioSessionControl
    private let retryDelays: [Duration]
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var owned = false
    private var releasePending = false
    private var generation = 0

    public init(control: any AudioSessionControl, spec: CarPlayAudioSpec = .conversation,
                retryDelays: [Duration] = CarPlayAudioSessionOwner.releaseBackoff,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.control = control
        self.spec = spec
        self.retryDelays = retryDelays
        self.log = log
    }

    /// ¿La conversación tiene la sesión tomada?
    public var isOwned: Bool { lock.withLock { owned } }

    /// ¿Se soltó pero `setActive(false)` todavía no lo logró?
    public var isReleasePending: Bool { lock.withLock { releasePending } }

    public func activateConversation() throws {
        lock.lock()
        generation += 1
        do {
            try control.configure(spec)
            try control.setActive(true, notifyOthers: false)
            owned = true
            releasePending = false
            lock.unlock()
        } catch {
            owned = false
            releasePending = true
            let current = generation
            lock.unlock()
            settle(current)
            throw error
        }
    }

    public func releaseConversation() {
        let current: Int? = lock.withLock {
            guard owned || releasePending else { return nil }
            return markReleased()
        }
        if let current { settle(current) }
    }

    /// La escena se fue o el carro se desconectó: se suelta aunque la
    /// conversación no la tuviera (otra parte de la app pudo dejarla activa).
    public func ensureReleased() {
        let current = lock.withLock { markReleased() }
        settle(current)
    }

    private func markReleased() -> Int {
        owned = false
        releasePending = true
        generation += 1
        return generation
    }

    private func settle(_ current: Int) {
        guard !attempt(current) else { return }
        let delays = retryDelays
        Task.detached { [weak self] in
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard let self else { return }
                if self.attempt(current) { return }
            }
            self?.log("setActive(false) sigue fallando tras \(delays.count) reintentos: queda pendiente")
        }
    }

    /// true = nada más que hacer (logrado, o la sesión se re-tomó entretanto).
    private func attempt(_ current: Int) -> Bool {
        lock.withLock {
            guard current == generation, releasePending else { return true }
            do {
                try control.setActive(false, notifyOthers: spec.notifiesOthersOnRelease)
            } catch {
                log("setActive(false) falló (\(error)); se reintenta")
                return false
            }
            releasePending = false
            control.restoreMixable()
            return true
        }
    }

    // MARK: AudioSessionPort (captura y TTS de las gafas reutilizados)

    /// Sin dueño, nada se re-activa: una captura o un TTS rezagados (cancelados
    /// por la desconexión) jamás vuelven a tomar la sesión, y se enteran
    /// (`AudioSessionNotOwned`): el TTS no habla.
    private func reassert() throws {
        try lock.withLock {
            guard owned else { throw AudioSessionNotOwned() }
            try control.setActive(true, notifyOthers: false)
        }
    }

    public func hfpInputAvailable() -> Bool { false }
    public func activateHFP() throws { try reassert() }
    public func currentInputIsHFP() -> Bool { false }
    public func activatePhoneMic() throws { try reassert() }
    public func activatePlaybackA2DP() throws { try reassert() }
    /// Entre escuchar y hablar no se suelta (la música no salta en cada fase):
    /// la suelta la conversación con `releaseConversation`. Pero es el aviso de
    /// que la captura ya paró su engine y su tap: si había una liberación
    /// pendiente (falló por I/O en curso), se reintenta YA.
    public func deactivate() {
        let current: Int? = lock.withLock { releasePending ? generation : nil }
        if let current { _ = attempt(current) }
    }
}
