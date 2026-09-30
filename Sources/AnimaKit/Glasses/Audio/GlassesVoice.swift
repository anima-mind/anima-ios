// GlassesVoice.swift — el pipeline de voz manos-libres (doc 05 §4.2) como
// lógica PURA + puertos. El audio NO es DAT: es Bluetooth del sistema.
//   HFP (bidireccional, 8 kHz mono, beamforming) ↔ A2DP (salida estéreo):
//   MUTUAMENTE EXCLUYENTES. Captura = HFP; respuesta = A2DP.
//   La ruta HFP tarda ~2 s en asentarse y hay que VERIFICARLA: si no asentó,
//   reintentar 1 vez y luego degradar al micrófono del teléfono.
// El STT es on-device (es-CO): el audio crudo jamás sale del teléfono.
// Implementación iOS real: GlassesAudioIO.swift (#if os(iOS)).

import Foundation

public enum VoiceRoute: String, Sendable, Equatable {
    case glassesHFP
    case phoneMic
}

/// La sesión de audio del sistema (AVAudioSession), fina y mockeable.
public protocol AudioSessionPort: Sendable {
    /// ¿Hay un input Bluetooth HFP disponible (las gafas)?
    func hfpInputAvailable() -> Bool
    /// .playAndRecord + .allowBluetoothHFP + preferir el input HFP.
    func activateHFP() throws
    /// ¿La ruta actual efectivamente usa el input HFP?
    func currentInputIsHFP() -> Bool
    /// .playAndRecord con el mic del teléfono (fallback).
    func activatePhoneMic() throws
    /// .playback + .allowBluetoothA2DP: el TTS sale por los parlantes de las gafas.
    func activatePlaybackA2DP() throws
    func deactivate()
}

public enum AudioRoutePlanner {
    /// Configura la captura con la política del §4.2 y devuelve la ruta real.
    public static func settleCapture(
        _ session: any AudioSessionPort,
        settle: TimeInterval = 2,
        sleep: @Sendable (TimeInterval) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
    ) async -> VoiceRoute {
        if session.hfpInputAvailable() {
            for _ in 0..<2 {   // intento + 1 reintento
                if (try? session.activateHFP()) != nil {
                    await sleep(settle)
                    if session.currentInputIsHFP() { return .glassesHFP }
                }
            }
        }
        try? session.activatePhoneMic()
        return .phoneMic
    }
}

/// Fin de turno por silencio (handoff: pausa ≈ 1.2 s termina el turno).
/// Puro: se alimenta con los parciales del reconocedor y el reloj.
public struct TurnEndDetector: Sendable, Equatable {
    public var silence: TimeInterval
    public var maxDuration: TimeInterval
    public private(set) var transcript = ""
    public private(set) var lastChange: Date?
    public private(set) var startedAt: Date?

    public init(silence: TimeInterval = 1.2, maxDuration: TimeInterval = 30) {
        self.silence = silence
        self.maxDuration = maxDuration
    }

    public mutating func start(at date: Date) { startedAt = date }

    /// Un parcial del reconocedor. Solo cuenta como cambio si el texto cambió.
    public mutating func partial(_ text: String, at date: Date) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean != transcript else { return }
        transcript = clean
        lastChange = date
    }

    /// ¿Terminó el turno? (silencio tras haber oído algo, o duración máxima).
    public func isFinished(at date: Date) -> Bool {
        if let startedAt, date.timeIntervalSince(startedAt) >= maxDuration { return true }
        guard !transcript.isEmpty, let lastChange else { return false }
        return date.timeIntervalSince(lastChange) >= silence
    }
}

/// Captura de voz: asienta la ruta, reconoce on-device y termina por silencio.
public protocol VoiceCapturePort: Sendable {
    /// Devuelve el transcript (nil si no se oyó nada o se canceló). `onRoute`
    /// informa la ruta real (gafas HFP o fallback al teléfono).
    func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void) async -> String?
    func cancel()
}

/// Salida por voz (TTS). `speak` retorna al terminar de hablar.
public protocol SpeechOutputPort: Sendable {
    func speak(_ text: String) async
    func stop()
}

/// Sin audio (UI tests, macOS): no oye nada, no dice nada.
public struct SilentVoice: VoiceCapturePort, SpeechOutputPort {
    public init() {}
    public func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void) async -> String? { nil }
    public func cancel() {}
    public func speak(_ text: String) async {}
    public func stop() {}
}
