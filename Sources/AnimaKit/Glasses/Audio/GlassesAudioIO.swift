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
public final class GlassesVoiceCapture: VoiceCapturePort, @unchecked Sendable {
    private let audio: any AudioSessionPort
    private let locale: Locale
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var detector = TurnEndDetector()
    private var cancelled = false

    public init(audio: any AudioSessionPort = SystemAudioSession(), locale: Locale = Locale(identifier: "es-CO")) {
        self.audio = audio
        self.locale = locale
    }

    public func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void) async -> String? {
        withLock { cancelled = false; detector = TurnEndDetector() }
        guard await Self.authorized(), let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            return nil
        }
        let route = await AudioRoutePlanner.settleCapture(audio)
        onRoute(route)
        guard !isCancelled else { return nil }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true   // el audio crudo no sale del teléfono
        request.shouldReportPartialResults = true
        let engine = AVAudioEngine()
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.inputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch { return nil }
        withLock {
            self.engine = engine
            self.request = request
            detector.start(at: Date())
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            self.lock.lock()
            self.detector.partial(result.bestTranscription.formattedString, at: Date())
            self.lock.unlock()
        }

        while !isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let done = withLock { detector.isFinished(at: Date()) }
            if done || Task.isCancelled { break }
        }
        let (transcript, wasCancelled) = withLock { (detector.transcript, cancelled) }
        teardown()
        return wasCancelled || transcript.isEmpty ? nil : transcript
    }

    public func cancel() {
        withLock { cancelled = true }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Teardown: removeTap → engine.stop() → endAudio (receta Relay §9).
    private func teardown() {
        lock.lock()
        let engine = self.engine, request = self.request, task = self.task
        self.engine = nil; self.request = nil; self.task = nil
        lock.unlock()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()
        task?.cancel()
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

/// TTS corto por A2DP (parlantes de las gafas). AVSpeechSynthesizer v1 (doc 05 §9 #5).
public final class GlassesSpeaker: NSObject, SpeechOutputPort, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let audio: any AudioSessionPort
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    public init(audio: any AudioSessionPort = SystemAudioSession()) {
        self.audio = audio
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String) async {
        guard !text.isEmpty else { return }
        try? audio.activatePlaybackA2DP()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "es-CO") ?? AVSpeechSynthesisVoice(language: "es-MX")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store(cont)
            synthesizer.speak(utterance)
        }
    }

    private func store(_ cont: CheckedContinuation<Void, Never>) {
        lock.lock(); continuation = cont; lock.unlock()
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        finish()
    }

    private func finish() {
        lock.lock(); let cont = continuation; continuation = nil; lock.unlock()
        cont?.resume()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finish() }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish() }
}
#endif
