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
}

/// La sesión ya no es de quien quiere usarla (la conversación la soltó): una
/// captura o un TTS rezagados no la re-activan y no suenan.
public struct AudioSessionNotOwned: Error, Equatable {
    public init() {}
}

public final class CarPlayAudioSessionOwner: CarPlayAudioPort, AudioSessionPort, @unchecked Sendable {
    public let spec: CarPlayAudioSpec
    private let control: any AudioSessionControl
    private let lock = NSLock()
    private var owned = false

    public init(control: any AudioSessionControl, spec: CarPlayAudioSpec = .conversation) {
        self.control = control
        self.spec = spec
    }

    /// ¿La conversación tiene la sesión tomada?
    public var isOwned: Bool { lock.withLock { owned } }

    public func activateConversation() throws {
        try lock.withLock {
            try control.configure(spec)
            try control.setActive(true, notifyOthers: false)
            owned = true
        }
    }

    public func releaseConversation() {
        lock.withLock {
            guard owned else { return }
            owned = false
            try? control.setActive(false, notifyOthers: spec.notifiesOthersOnRelease)
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
    /// la suelta la conversación con `releaseConversation`.
    public func deactivate() {}
}
