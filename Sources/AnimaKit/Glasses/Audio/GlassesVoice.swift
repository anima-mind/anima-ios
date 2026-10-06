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

/// Por qué no se pudo escuchar: `message` va al HUD (texto fijo por causa),
/// `description` al diagnóstico (con el detalle crudo).
public enum VoiceCaptureFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case speechPermissionDenied
    case microphonePermissionDenied
    case recognizerUnavailable(String)
    /// El input no tiene un formato usable (0 Hz / 0 canales: ruta sin asentar).
    /// `route` lo completa el ciclo de captura (el reconocedor no la conoce).
    case microphoneUnavailable(route: VoiceRoute?, detail: String)
    case engineFailed(String)

    public static let heading = "No pude usar el micrófono."

    /// Una línea fija por causa para el HUD (sin detalle crudo).
    public var message: String {
        switch self {
        case .speechPermissionDenied: return "Sin permiso de dictado. Actívalo en Ajustes del iPhone → Anima."
        case .microphonePermissionDenied: return "Sin permiso de micrófono. Actívalo en Ajustes del iPhone → Anima."
        case .recognizerUnavailable: return "El dictado en español no está disponible en este iPhone."
        case .microphoneUnavailable(let route, _):
            return route == .phoneMic ? "Mic del teléfono no disponible. Reintenta."
                                      : "Mic de las gafas no disponible. Reintenta."
        case .engineFailed: return "No pude arrancar el micrófono. Reintenta."
        }
    }

    /// Para el diagnóstico: la causa con el detalle crudo.
    public var description: String {
        switch self {
        case .speechPermissionDenied: return "sin permiso de dictado"
        case .microphonePermissionDenied: return "sin permiso de micrófono"
        case .recognizerUnavailable(let why): return "dictado no disponible: \(why)"
        case .microphoneUnavailable(let route, let detail):
            return "mic no disponible (ruta \(route?.rawValue ?? "?")): \(detail)"
        case .engineFailed(let why): return "el audio no arrancó: \(why)"
        }
    }
}

/// El guard del tap: `installTap` con 0 Hz / 0 canales lanza una NSException
/// (crash, no `throws`). Que el input HFP (8 kHz) y la salida del nodo (48 kHz)
/// difieran es normal: el tap se instala con el formato de SALIDA del nodo, así
/// que solo se exige que ambos formatos sean usables.
public enum AudioInputFormatGuard {
    public static func check(sampleRate: Double, channels: UInt32) throws(VoiceCaptureFailure) {
        guard sampleRate > 0, channels > 0 else {
            throw .microphoneUnavailable(route: nil, detail: "formato inválido \(Int(sampleRate)) Hz · \(channels) ch")
        }
    }

    /// `input` = `inputFormat(forBus: 0)`; `tap` = `outputFormat(forBus: 0)`, el
    /// formato con el que se instala el tap.
    public static func check(input: (sampleRate: Double, channels: UInt32),
                             tap: (sampleRate: Double, channels: UInt32)) throws(VoiceCaptureFailure) {
        try check(sampleRate: input.sampleRate, channels: input.channels)
        try check(sampleRate: tap.sampleRate, channels: tap.channels)
    }
}

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

/// Resultado del asentamiento (diagnóstico): ruta, espera total e intentos HFP.
public struct RouteSettlement: Sendable, Equatable {
    public var route: VoiceRoute
    public var waited: TimeInterval
    public var attempts: Int
    /// Había input HFP disponible (gafas conectadas por Bluetooth).
    public var hfpAvailable: Bool
}

public enum AudioRoutePlanner {
    /// Configura la captura con la política del §4.2 y devuelve la ruta real.
    /// Secuencia (doc DAT + Relay, verificada en hardware): `.playAndRecord` +
    /// `.allowBluetoothHFP` → `setActive` → `setPreferredInput(HFP)` → SONDEAR
    /// `currentRoute.inputs` cada `poll` hasta `settle` (salida temprana, típico
    /// <600 ms). Solo DESPUÉS se crea el engine y se lee el formato.
    public static func settleCapture(
        _ session: any AudioSessionPort,
        settle: TimeInterval = 2,
        poll: TimeInterval = 0.1,
        sleep: @Sendable (TimeInterval) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
    ) async -> VoiceRoute {
        await self.settle(session, settle: settle, poll: poll, sleep: sleep).route
    }

    public static func settle(
        _ session: any AudioSessionPort,
        settle: TimeInterval = 2,
        poll: TimeInterval = 0.1,
        sleep: @Sendable (TimeInterval) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
    ) async -> RouteSettlement {
        var waited: TimeInterval = 0
        var attempts = 0
        let available = session.hfpInputAvailable()
        if available {
            for _ in 0..<2 {   // intento + 1 reintento
                attempts += 1
                if (try? session.activateHFP()) != nil {
                    var attemptWaited: TimeInterval = 0
                    while true {
                        if session.currentInputIsHFP() {
                            return RouteSettlement(route: .glassesHFP, waited: waited, attempts: attempts, hfpAvailable: true)
                        }
                        guard attemptWaited < settle else { break }
                        let step = min(poll, settle - attemptWaited)
                        await sleep(step)
                        attemptWaited += step
                        waited += step
                    }
                }
            }
        }
        try? session.activatePhoneMic()
        return RouteSettlement(route: .phoneMic, waited: waited, attempts: attempts, hfpAvailable: available)
    }

    /// Suelta la ruta de captura al terminar (silencio, cancel o error), en el
    /// orden de la doc DAT: (tap y engine ya parados) → `setActive(false)` →
    /// `.playback` A2DP. Salir de .playAndRecord cierra el SCO/HFP: si queda
    /// abierto, el firmware de las gafas sigue mostrando la UI de llamada.
    public static func releaseCapture(_ session: any AudioSessionPort) {
        session.deactivate()
        try? session.activatePlaybackA2DP()
    }
}

/// El reconocedor (tap del AVAudioEngine + tarea SFSpeech) detrás de un puerto.
public protocol SpeechRecognitionPort: Sendable {
    /// Instala el tap, arranca el engine y la tarea. Lanza si el formato del
    /// input no es usable (`VoiceCaptureFailure`) o si el engine no arranca.
    func start(onPartial: @escaping @Sendable (String) -> Void) throws
    /// Igual, avisando si la captura se interrumpe a mitad (cambio de ruta /
    /// `AVAudioEngineConfigurationChange`, error del dictado): el ciclo termina
    /// limpio conservando lo oído.
    func start(onPartial: @escaping @Sendable (String) -> Void,
               onInterrupted: @escaping @Sendable (String) -> Void) throws
    /// Teardown: removeTap → engine.stop() → endAudio → cancel (receta Relay §9).
    func stop()
}

public extension SpeechRecognitionPort {
    func start(onPartial: @escaping @Sendable (String) -> Void,
               onInterrupted: @escaping @Sendable (String) -> Void) throws {
        try start(onPartial: onPartial)
    }
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

    private let diagnostics: GlassesDiagnostics?

    public init(audio: any AudioSessionPort, detector: TurnEndDetector = TurnEndDetector(),
                settle: TimeInterval = 2, poll: TimeInterval = 0.1,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { s in
                    try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
                },
                diagnostics: GlassesDiagnostics? = nil) {
        self.audio = audio
        self.template = detector
        self.detector = detector
        self.settle = settle
        self.poll = poll
        self.sleep = sleep
        self.diagnostics = diagnostics
    }

    /// `recognizer` resuelve permisos y disponibilidad ANTES de tocar el audio:
    /// nil = no se captura (y la sesión de audio queda intacta).
    public func run(recognizer: () async -> (any SpeechRecognitionPort)?,
                    onRoute: @escaping @Sendable (VoiceRoute) -> Void,
                    onPartial: (@Sendable (String) -> Void)? = nil) async -> String? {
        await run(resolve: {
            if let found = await recognizer() { return .success(found) }
            return .failure(.recognizerUnavailable("sin reconocedor"))
        }, onRoute: onRoute, onPartial: onPartial)
    }

    /// El ciclo con causa de fallo: permisos → ruta asentada → reconocedor
    /// (guard de formato) → fin por silencio / "Listo" / interrupción →
    /// teardown → soltar la ruta. `onFailure` recibe POR QUÉ no se escuchó.
    public func run(resolve: () async -> Result<any SpeechRecognitionPort, VoiceCaptureFailure>,
                    onRoute: @escaping @Sendable (VoiceRoute) -> Void,
                    onPartial: (@Sendable (String) -> Void)? = nil,
                    onFailure: (@Sendable (VoiceCaptureFailure) -> Void)? = nil) async -> String? {
        withLock { cancelled = false; finishRequested = false; detector = template }
        let recognizer: any SpeechRecognitionPort
        switch await resolve() {
        case .success(let found):
            recognizer = found
        case .failure(let failure):
            log("sin captura: \(failure)")
            onFailure?(failure)
            return nil
        }
        let settlement = await AudioRoutePlanner.settle(audio, settle: settle, poll: min(poll, 0.1), sleep: sleep)
        log("ruta \(settlement.route.rawValue) · settle \(Int(settlement.waited * 1000)) ms · "
            + "\(settlement.attempts) intento(s) HFP · HFP disponible: \(settlement.hfpAvailable ? "sí" : "no")")
        onRoute(settlement.route)
        guard !isCancelled else {
            AudioRoutePlanner.releaseCapture(audio)
            log("cancelada antes del engine · ruta soltada")
            return nil
        }
        do {
            try recognizer.start(onPartial: { [weak self] text in
                self?.partial(text)
                onPartial?(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }, onInterrupted: { [weak self] why in
                self?.log("interrumpida: \(why)")
                self?.finish()
            })
        } catch {
            recognizer.stop()
            AudioRoutePlanner.releaseCapture(audio)
            var failure = (error as? VoiceCaptureFailure) ?? .engineFailed("\(error)")
            if case .microphoneUnavailable(_, let detail) = failure {
                failure = .microphoneUnavailable(route: settlement.route, detail: detail)
            }
            log("sin tap: \(failure) · ruta soltada")
            onFailure?(failure)
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
        log("teardown: tap → engine → setActive(false) → A2DP · \(wasCancelled ? "cancelada" : "\(transcript.count) caracteres")")
        return wasCancelled || transcript.isEmpty ? nil : transcript
    }

    private func log(_ message: String) {
        diagnostics?.record(.audio, message)
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

/// Fin de turno por silencio (handoff: pausa ≈ 1.2 s termina el turno en las
/// gafas). Puro: se alimenta con los parciales del reconocedor y el reloj.
public struct TurnEndDetector: Sendable, Equatable {
    /// Nota de voz del composer del teléfono (campo batch 5 #1: "se corta muy
    /// rápido y no puedo ni respirar"): 2.5 s de silencio tras el último parcial.
    public static let phoneDictationSilence: TimeInterval = 2.5
    /// Escucha mínima antes de poder cortar por silencio en el teléfono.
    public static let phoneDictationMinListen: TimeInterval = 1.5
    public static let phoneDictationMaxDuration: TimeInterval = 60

    /// Composer del teléfono: pausas de respiración sin cortar.
    public static let phoneDictation = TurnEndDetector(silence: phoneDictationSilence,
                                                       maxDuration: phoneDictationMaxDuration,
                                                       minListen: phoneDictationMinListen)

    public var silence: TimeInterval
    public var maxDuration: TimeInterval
    public var minListen: TimeInterval
    public private(set) var transcript = ""
    public private(set) var lastChange: Date?
    public private(set) var startedAt: Date?

    public init(silence: TimeInterval = 1.2, maxDuration: TimeInterval = 30, minListen: TimeInterval = 0) {
        self.silence = silence
        self.maxDuration = maxDuration
        self.minListen = minListen
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
        if let startedAt, date.timeIntervalSince(startedAt) < minListen { return false }
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
    /// Igual, informando POR QUÉ no se pudo escuchar (permisos, mic, engine).
    func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void,
                 onPartial: @escaping @Sendable (String) -> Void,
                 onFailure: @escaping @Sendable (VoiceCaptureFailure) -> Void) async -> String?
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
    func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void,
                 onPartial: @escaping @Sendable (String) -> Void,
                 onFailure: @escaping @Sendable (VoiceCaptureFailure) -> Void) async -> String? {
        await capture(onRoute: onRoute, onPartial: onPartial)
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
