import Foundation
import Testing
@testable import AnimaKit

// Campo #1: tras hablar, las gafas quedaban "en llamada" — el teardown de la
// captura no soltaba el SCO/HFP hasta el próximo TTS. Ahora toda salida del
// ciclo (silencio, cancel, error del engine) suelta la ruta ANTES de cualquier speak.

@Suite("Campo — la captura suelta HFP al terminar")
struct GlassesCaptureReleaseTests {

    /// Bitácora ordenada compartida por la sesión de audio, el reconocedor y el TTS.
    final class Log: @unchecked Sendable {
        let entries = Locked<[String]>([])
        func add(_ e: String) { entries.mutate { $0.append(e) } }
        func index(_ e: String) -> Int? { entries.value.firstIndex(of: e) }
    }

    final class Audio: AudioSessionPort, @unchecked Sendable {
        let log: Log
        let a2dpFails: Bool
        init(_ log: Log, a2dpFails: Bool = false) { self.log = log; self.a2dpFails = a2dpFails }
        func hfpInputAvailable() -> Bool { true }
        func activateHFP() throws { log.add("hfp") }
        func currentInputIsHFP() -> Bool { true }
        func activatePhoneMic() throws { log.add("phoneMic") }
        func activatePlaybackA2DP() throws {
            if a2dpFails { log.add("a2dp-failed"); throw MockError("a2dp") }
            log.add("a2dp")
        }
        func deactivate() { log.add("deactivate") }
    }

    final class Recognizer: SpeechRecognitionPort, @unchecked Sendable {
        let log: Log
        let partials: [String]
        let startError: Error?
        init(_ log: Log, partials: [String] = [], startError: Error? = nil) {
            self.log = log
            self.partials = partials
            self.startError = startError
        }
        func start(onPartial: @escaping @Sendable (String) -> Void) throws {
            if let startError { throw startError }
            log.add("start")
            for p in partials { onPartial(p) }
        }
        func stop() { log.add("stop") }
    }

    final class Speaker: SpeechOutputPort, @unchecked Sendable {
        let log: Log
        init(_ log: Log) { self.log = log }
        func speak(_ text: String) async { log.add("speak") }
        func stop() {}
    }

    static func loop(_ audio: Audio) -> VoiceCaptureLoop {
        VoiceCaptureLoop(audio: audio, detector: TurnEndDetector(silence: 0.03, maxDuration: 5),
                         settle: 0, poll: 0.005, sleep: { s in try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) })
    }

    @Test func finPorSilencioSueltaHFPAntesDelTTS() async throws {
        let log = Log()
        let audio = Audio(log)
        let loop = Self.loop(audio)
        let routes = Locked<[VoiceRoute]>([])
        let transcript = await loop.run(recognizer: { Recognizer(log, partials: ["qué tengo mañana"]) },
                                        onRoute: { r in routes.mutate { $0.append(r) } })
        #expect(transcript == "qué tengo mañana")
        #expect(routes.value == [.glassesHFP])
        // La pantalla "Te escuché" ocurre aquí: HFP ya está suelto.
        #expect(log.entries.value == ["hfp", "start", "stop", "a2dp"])
        await Speaker(log).speak("Mañana: standup a las 9.")
        let a2dp = try #require(log.index("a2dp"))
        let speak = try #require(log.index("speak"))
        let stop = try #require(log.index("stop"))
        #expect(stop < a2dp)   // receta Relay intacta: teardown primero, liberación después
        #expect(a2dp < speak)
    }

    @Test func cancelDuranteLaEscuchaSueltaHFP() async {
        let log = Log()
        let audio = Audio(log)
        let loop = Self.loop(audio)
        let task = Task { await loop.run(recognizer: { Recognizer(log) }, onRoute: { _ in }) }
        _ = await eventually { log.index("start") != nil }
        loop.cancel()
        #expect(await task.value == nil)
        #expect(log.entries.value == ["hfp", "start", "stop", "a2dp"])
    }

    @Test func cancelAntesDeArrancarElEngineSueltaHFP() async {
        let log = Log()
        let audio = Audio(log)
        let loop = Self.loop(audio)
        let result = await loop.run(recognizer: { Recognizer(log) }, onRoute: { _ in loop.cancel() })
        #expect(result == nil)
        #expect(log.entries.value == ["hfp", "a2dp"])
    }

    @Test func errorDelEngineSueltaHFPYSiA2DPFallaDesactiva() async {
        let log = Log()
        let audio = Audio(log, a2dpFails: true)
        let loop = Self.loop(audio)
        let result = await loop.run(recognizer: { Recognizer(log, startError: MockError("engine")) }, onRoute: { _ in })
        #expect(result == nil)
        #expect(log.entries.value == ["hfp", "stop", "a2dp-failed", "deactivate"])
    }

    @Test func sinPermisoNoSeTocaElAudio() async {
        let log = Log()
        let loop = Self.loop(Audio(log))
        let routes = Locked(0)
        let result = await loop.run(recognizer: { nil }, onRoute: { _ in routes.mutate { $0 += 1 } })
        #expect(result == nil)
        #expect(log.entries.value.isEmpty)
        #expect(routes.value == 0)
    }

    @Test func silencioSinHablaNoDevuelveTranscript() async {
        let log = Log()
        let loop = VoiceCaptureLoop(audio: Audio(log), detector: TurnEndDetector(silence: 0.01, maxDuration: 0.02),
                                    settle: 0, poll: 0.005)
        let result = await loop.run(recognizer: { Recognizer(log) }, onRoute: { _ in })
        #expect(result == nil)
        #expect(log.entries.value.last == "a2dp")
    }
}
