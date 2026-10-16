// CarPlayAudioIO.swift — AVAudioSession detrás de AudioSessionControl. Capa
// humilde: quién la toma y la suelta vive en CarPlayAudioSessionOwner y
// CarPlayConversation (testeados con un doble de la sesión).
// Configuración de Apple para "voice-based conversation" (WWDC26 "Rev up your
// CarPlay app"): .playAndRecord, modo .default, sin mezclar. En CarPlay el
// micrófono y los parlantes son los del carro (la ruta la pone el sistema).

#if os(iOS) && canImport(AVFoundation)
import AVFoundation

public struct SystemAudioSessionControl: AudioSessionControl {
    public init() {}

    public func configure(_ spec: CarPlayAudioSpec) throws {
        let options: AVAudioSession.CategoryOptions = spec.mixesWithOthers ? [.mixWithOthers] : []
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: options)
    }

    public func setActive(_ active: Bool, notifyOthers: Bool) throws {
        try AVAudioSession.sharedInstance().setActive(active, options: notifyOthers ? .notifyOthersOnDeactivation : [])
    }
}

extension CarPlayAudioSessionOwner {
    /// La sesión real del proceso.
    public static func system() -> CarPlayAudioSessionOwner {
        CarPlayAudioSessionOwner(control: SystemAudioSessionControl())
    }
}
#endif
