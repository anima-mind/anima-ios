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
    /// La ruta se SONDEA cada `poll` con salida temprana apenas asienta (patrón
    /// Relay SpeechVoiceSession): máximo `settle` por intento, típico <600 ms.
    public static func settleCapture(
        _ session: any AudioSessionPort,
        settle: TimeInterval = 2,
        poll: TimeInterval = 0.1,
        sleep: @Sendable (TimeInterval) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
    ) async -> VoiceRoute {
        if session.hfpInputAvailable() {
            for _ in 0..<2 {   // intento + 1 reintento
                if (try? session.activateHFP()) != nil {
                    var waited: TimeInterval = 0
                    while true {
                        if session.currentInputIsHFP() { return .glassesHFP }
                        guard waited < settle else { break }
                        let step = min(poll, settle - waited)
                        await sleep(step)
                        waited += step
                    }
                }
            }
        }
        try? session.activatePhoneMic()
        return .phoneMic
    }

    /// Suelta la ruta de captura al terminar (silencio, cancel o error). Salir de
    /// .playAndRecord cierra el SCO/HFP: si queda abierto, el firmware de las
    /// gafas sigue mostrando la UI de llamada hasta el próximo TTS. A2DP deja
    /// además la salida lista para la respuesta; si falla, se desactiva la sesión.
    public static func releaseCapture(_ session: any AudioSessionPort) {
        do { try session.activatePlaybackA2DP() } catch { session.deactivate() }
    }
}

/// El reconocedor (tap del AVAudioEngine + tarea SFSpeech) detrás de un puerto.
public protocol SpeechRecognitionPort: Sendable {
    /// Instala el tap, arranca el engine y la tarea. Lanza si el engine no arranca.
    func start(onPartial: @escaping @Sendable (String) -> Void) throws
    /// Teardown: removeTap → engine.stop() → endAudio → cancel (receta Relay §9).
    func stop()
}

/// El ciclo de UNA captura: asentar ruta → reconocer → fin por silencio →
/// teardown del reconocedor → soltar la ruta HFP. Cualquier salida tras tocar
/// la sesión de audio (silencio, cancel, error del engine) pasa por
/// `releaseCapture`: el canal de "llamada" nunca queda abierto.
public final class VoiceCaptureLoop: @unchecked Sendable {
    private let audio: any AudioSessionPort
    private let template: TurnEndDetector
    private let settle: TimeInterval
    private let poll: TimeInterval
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let lock = NSLock()
    private var detector: TurnEndDetector
    private var cancelled = false
    private var finishRequested = false

    public init(audio: any AudioSessionPort, detector: TurnEndDetector = TurnEndDetector(),
                settle: TimeInterval = 2, poll: TimeInterval = 0.1,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { s in
                    try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
                }) {
        self.audio = audio
        self.template = detector
        self.detector = detector
        self.settle = settle
        self.poll = poll
        self.sleep = sleep
    }

    /// `recognizer` resuelve permisos y disponibilidad ANTES de tocar el audio:
    /// nil = no se captura (y la sesión de audio queda intacta).
    public func run(recognizer: () async -> (any SpeechRecognitionPort)?,
                    onRoute: @escaping @Sendable (VoiceRoute) -> Void,
                    onPartial: (@Sendable (String) -> Void)? = nil) async -> String? {
        withLock { cancelled = false; finishRequested = false; detector = template }
        guard let recognizer = await recognizer() else { return nil }
        let route = await AudioRoutePlanner.settleCapture(audio, settle: settle, poll: min(poll, 0.1), sleep: sleep)
        onRoute(route)
        guard !isCancelled else {
            AudioRoutePlanner.releaseCapture(audio)
            return nil
        }
        do {
            try recognizer.start { [weak self] text in
                self?.partial(text)
                onPartial?(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } catch {
            recognizer.stop()
            AudioRoutePlanner.releaseCapture(audio)
            return nil
        }
        withLock { detector.start(at: Date()) }
        while !isCancelled {
            await sleep(poll)
            let done = withLock { finishRequested || detector.isFinished(at: Date()) }
            if done || Task.isCancelled { break }
        }
        let (transcript, wasCancelled) = withLock { (detector.transcript, cancelled) }
        recognizer.stop()
        AudioRoutePlanner.releaseCapture(audio)
        return wasCancelled || transcript.isEmpty ? nil : transcript
    }

    public func cancel() {
        withLock { cancelled = true }
    }

    /// "Listo": corta la escucha conservando lo oído.
    public func finish() {
        withLock { finishRequested = true }
    }

    private func partial(_ text: String) {
        withLock { detector.partial(text, at: Date()) }
    }

    private var isCancelled: Bool { withLock { cancelled } }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
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
    /// Igual, con el transcript EN VIVO (parciales) para mostrarlo mientras habla.
    func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void,
                 onPartial: @escaping @Sendable (String) -> Void) async -> String?
    /// Descarta: la captura devuelve nil.
    func cancel()
    /// "Listo": termina YA conservando lo oído (sin esperar el silencio).
    func finish()
}

public extension VoiceCapturePort {
    func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void,
                 onPartial: @escaping @Sendable (String) -> Void) async -> String? {
        await capture(onRoute: onRoute)
    }
    func finish() {}
}

/// Fuerza el micrófono del TELÉFONO (composer del chat): nunca toca HFP aunque
/// haya gafas conectadas — `settleCapture` va directo a `activatePhoneMic`.
public struct PhoneMicAudioSession: AudioSessionPort {
    private let base: any AudioSessionPort
    public init(_ base: any AudioSessionPort) { self.base = base }
    public func hfpInputAvailable() -> Bool { false }
    public func activateHFP() throws { try base.activatePhoneMic() }
    public func currentInputIsHFP() -> Bool { false }
    public func activatePhoneMic() throws { try base.activatePhoneMic() }
    public func activatePlaybackA2DP() throws { try base.activatePlaybackA2DP() }
    public func deactivate() { base.deactivate() }
}

/// Salida por voz (TTS). `speak` retorna al terminar de hablar.
public protocol SpeechOutputPort: Sendable {
    func speak(_ text: String) async
    /// Igual, informando el rango (UTF-16 de `text`) que se está pronunciando:
    /// alimenta el karaoke del HUD (HUDSpokenPager).
    func speak(_ text: String, onRange: @escaping @Sendable (NSRange) -> Void) async
    func stop()
}

public extension SpeechOutputPort {
    /// Salidas sin progreso (silenciosas, dobles): hablan sin reportar rangos.
    func speak(_ text: String, onRange: @escaping @Sendable (NSRange) -> Void) async {
        await speak(text)
    }
}

/// Sin audio (UI tests, macOS): no oye nada, no dice nada.
public struct SilentVoice: VoiceCapturePort, SpeechOutputPort {
    public init() {}
    public func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void) async -> String? { nil }
    public func cancel() {}
    public func speak(_ text: String) async {}
    public func stop() {}
}
