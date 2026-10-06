// GlassesAudioIO.swift — implementación iOS del pipeline de voz de las gafas
// (doc 05 §4.2, receta HFP del doc Relay §9 verificada en hardware). Capa
// humilde: la política (asentar ruta, reintento, fallback, fin por silencio)
// vive en GlassesVoice.swift (pura, testeada). Solo verificable en device con
// las gafas: calidad de HFP 8 kHz + es-CO on-device, latencia del cambio
// HFP→A2DP antes del TTS.

#if os(iOS) && canImport(AVFoundation) && canImport(Speech)
import AVFoundation
import Speech

/// AVAudioSession detrás del puerto.
public struct SystemAudioSession: AudioSessionPort {
    public init() {}

    private var session: AVAudioSession { .sharedInstance() }

    public func hfpInputAvailable() -> Bool {
        (try? session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])) != nil
            && session.availableInputs?.contains { $0.portType == .bluetoothHFP } == true
    }

    public func activateHFP() throws {
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        if let hfp = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try session.setPreferredInput(hfp)
        }
    }

    public func currentInputIsHFP() -> Bool {
        session.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
    }

    public func activatePhoneMic() throws {
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setPreferredInput(session.availableInputs?.first { $0.portType == .builtInMic })
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    public func activatePlaybackA2DP() throws {
        // HFP y A2DP son excluyentes: salir de playAndRecord libera la ruta 8 kHz.
        try session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothA2DP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    public func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// HFP → AVAudioEngine → SFSpeechRecognizer on-device (es-CO), fin por silencio.
/// El ciclo (ruta, silencio, teardown y liberación de HFP) vive en VoiceCaptureLoop.
/// Secuencia (doc DAT "HFP" + Relay SpeechVoiceSession, validada en hardware):
///   permisos (dictado + `AVAudioApplication.requestRecordPermission`) →
///   `.playAndRecord` + `.allowBluetoothHFP` → `setActive` → `setPreferredInput(HFP)`
///   → esperar ≤2 s a que `currentRoute.inputs` tenga `.bluetoothHFP` → SOLO
///   entonces engine + `inputFormat(forBus: 0)` → guard de formato → tap.
public final class GlassesVoiceCapture: VoiceCapturePort, @unchecked Sendable {
    private let locale: Locale
    private let loop: VoiceCaptureLoop
    private let diagnostics: GlassesDiagnostics?

    public init(audio: any AudioSessionPort = SystemAudioSession(), locale: Locale = Locale(identifier: "es-CO"),
                detector: TurnEndDetector = TurnEndDetector(),
                diagnostics: GlassesDiagnostics? = nil) {
        self.locale = locale
        self.diagnostics = diagnostics
        self.loop = VoiceCaptureLoop(audio: audio, detector: detector, diagnostics: diagnostics)
    }

    public func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void) async -> String? {
        await capture(onRoute: onRoute, onPartial: { _ in }, onFailure: { _ in })
    }

    public func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void,
                        onPartial: @escaping @Sendable (String) -> Void) async -> String? {
        await capture(onRoute: onRoute, onPartial: onPartial, onFailure: { _ in })
    }

    public func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void,
                        onPartial: @escaping @Sendable (String) -> Void,
                        onFailure: @escaping @Sendable (VoiceCaptureFailure) -> Void) async -> String? {
        let locale = self.locale
        let diagnostics = self.diagnostics
        return await loop.run(resolve: {
            guard await Self.authorized() else { return .failure(.speechPermissionDenied) }
            guard await Self.microphoneGranted() else { return .failure(.microphonePermissionDenied) }
            guard let recognizer = Self.onDeviceRecognizer(preferred: locale) else {
                return .failure(.recognizerUnavailable("sin dictado en el dispositivo para español"))
            }
            diagnostics?.record(.audio, "dictado \(recognizer.locale.identifier) on-device")
            return .success(SpeechRecognition(recognizer, log: { diagnostics?.record(.audio, $0) }))
        }, onRoute: onRoute, onPartial: onPartial, onFailure: onFailure)
    }

    public func cancel() {
        loop.cancel()
    }

    public func finish() {
        loop.finish()
    }

    /// El audio crudo jamás sale del teléfono: solo reconocedores on-device.
    /// es-CO primero; si el iPhone no tiene ese modelo, otra variante de español.
    static func onDeviceRecognizer(preferred: Locale) -> SFSpeechRecognizer? {
        let candidates = [preferred.identifier, "es-MX", "es-US", "es-ES"]
        for id in candidates {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)),
               recognizer.isAvailable, recognizer.supportsOnDeviceRecognition {
                return recognizer
            }
        }
        return nil
    }

    /// Permiso de micrófono (TCC normal; el primer uso muestra el diálogo).
    static func microphoneGranted() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        default: return false
        }
    }

    static func authorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
}

/// AVAudioEngine (tap del input) + SFSpeechAudioBufferRecognitionRequest on-device.
/// El engine se crea AQUÍ, después de asentar la ruta (nunca antes: un formato
/// leído con la ruta a medio cambiar es 0 Hz y `installTap` revienta).
final class SpeechRecognition: SpeechRecognitionPort, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var observer: NSObjectProtocol?
    private var stopped = false

    init(_ recognizer: SFSpeechRecognizer, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.recognizer = recognizer
        self.log = log
    }

    func start(onPartial: @escaping @Sendable (String) -> Void) throws {
        try start(onPartial: onPartial, onInterrupted: { _ in })
    }

    func start(onPartial: @escaping @Sendable (String) -> Void,
               onInterrupted: @escaping @Sendable (String) -> Void) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        let output = input.outputFormat(forBus: 0)
        let route = AVAudioSession.sharedInstance().currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        log("input \(Int(format.sampleRate)) Hz · \(format.channelCount) ch (salida \(Int(output.sampleRate)) Hz) · ruta [\(route)]")
        try AudioInputFormatGuard.check(sampleRate: format.sampleRate, channels: format.channelCount,
                                        outputSampleRate: output.sampleRate)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true   // el audio crudo no sale del teléfono
        request.shouldReportPartialResults = true
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard self?.isStopped == false else { return }
            onInterrupted("cambio de ruta de audio (AVAudioEngineConfigurationChange)")
        }
        lock.lock(); self.engine = engine; self.request = request; self.observer = observer; lock.unlock()
        engine.prepare()
        try engine.start()
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result { onPartial(result.bestTranscription.formattedString) }
            if let error, self?.isStopped == false {
                onInterrupted("dictado: \(error.localizedDescription)")
            }
        }
        lock.lock(); self.task = task; lock.unlock()
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// Teardown: removeTap → engine.stop() → endAudio (receta Relay §9). Idempotente.
    func stop() {
        lock.lock()
        let engine = self.engine, request = self.request, task = self.task, observer = self.observer
        self.engine = nil; self.request = nil; self.task = nil; self.observer = nil
        stopped = true
        lock.unlock()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()
        task?.cancel()
    }
}

/// TTS corto por A2DP (parlantes de las gafas). AVSpeechSynthesizer v1 (doc 05 §9 #5).
public final class GlassesSpeaker: NSObject, SpeechOutputPort, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let audio: any AudioSessionPort
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var onRange: (@Sendable (NSRange) -> Void)?

    public init(audio: any AudioSessionPort = SystemAudioSession()) {
        self.audio = audio
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String) async {
        await speak(text, onRange: { _ in })
    }

    public func speak(_ text: String, onRange: @escaping @Sendable (NSRange) -> Void) async {
        guard !text.isEmpty else { return }
        try? audio.activatePlaybackA2DP()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "es-CO") ?? AVSpeechSynthesisVoice(language: "es-MX")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store(cont, onRange)
            synthesizer.speak(utterance)
        }
    }

    /// Una sola continuation viva: si llega otra (speak solapado), la anterior
    /// se resuelve YA en vez de quedar colgada para siempre.
    private func store(_ cont: CheckedContinuation<Void, Never>, _ progress: @escaping @Sendable (NSRange) -> Void) {
        lock.lock()
        let previous = continuation
        continuation = cont
        onRange = progress
        lock.unlock()
        previous?.resume()
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        finish()
    }

    private func finish() {
        lock.lock(); let cont = continuation; continuation = nil; onRange = nil; lock.unlock()
        cont?.resume()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                  utterance: AVSpeechUtterance) {
        lock.lock(); let progress = onRange; lock.unlock()
        progress?(characterRange)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finish() }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish() }
}
#endif
