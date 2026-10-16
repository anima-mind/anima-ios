// CarPlayAudioIO.swift — la sesión de audio del carro detrás de los puertos
// (CarPlayAudioPort para la conversación; AudioSessionPort para reutilizar la
// captura y el TTS de las gafas sin su ruta HFP). Capa humilde: la política
// (cuándo se toma y se suelta) vive en CarPlayConversation, testeada.
// Configuración de Apple para "voice-based conversation" (WWDC26 "Rev up your
// CarPlay app"): .playAndRecord, modo .default, sin mezclar. En CarPlay el
// micrófono y los parlantes son los del carro (la ruta la pone el sistema).

#if os(iOS) && canImport(AVFoundation)
import AVFoundation

public struct CarPlayVoiceAudioSession: CarPlayAudioPort, AudioSessionPort {
    public let spec: CarPlayAudioSpec

    public init(spec: CarPlayAudioSpec = .conversation) {
        self.spec = spec
    }

    private var session: AVAudioSession { .sharedInstance() }

    public func activateConversation() throws {
        let options: AVAudioSession.CategoryOptions = spec.mixesWithOthers ? [.mixWithOthers] : []
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setActive(true)
    }

    public func releaseConversation() {
        try? session.setActive(false, options: spec.notifiesOthersOnRelease ? .notifyOthersOnDeactivation : [])
    }

    // MARK: AudioSessionPort — la conversación ya tiene la sesión tomada.

    public func hfpInputAvailable() -> Bool { false }
    public func activateHFP() throws { try activateConversation() }
    public func currentInputIsHFP() -> Bool { false }
    public func activatePhoneMic() throws { try activateConversation() }
    public func activatePlaybackA2DP() throws { try activateConversation() }
    /// La captura y el TTS no la sueltan entre escuchar y hablar (la música no
    /// salta en cada fase): la suelta la conversación con `releaseConversation`.
    public func deactivate() {}
}
#endif
