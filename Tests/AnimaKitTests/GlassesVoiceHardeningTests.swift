import Foundation
import Testing
@testable import AnimaKit

// El tap con 0 Hz / 0 canales es una NSException (crash, no `throws`): guard
// de formato ANTES del tap, causa visible en el HUD, interrupciones limpias y
// teardown en orden.

@Suite("Campo — voz desde las gafas: guard de formato, causas y teardown")
struct GlassesVoiceHardeningTests {

    final class Log: @unchecked Sendable {
        let entries = Locked<[String]>([])
        func add(_ e: String) { entries.mutate { $0.append(e) } }
    }

    final class Audio: AudioSessionPort, @unchecked Sendable {
        let log: Log
        let hfp: Bool
        init(_ log: Log, hfp: Bool = true) { self.log = log; self.hfp = hfp }
        func hfpInputAvailable() -> Bool { hfp }
        func activateHFP() throws { log.add("hfp") }
        func currentInputIsHFP() -> Bool { hfp }
        func activatePhoneMic() throws { log.add("phoneMic") }
        func activatePlaybackA2DP() throws { log.add("a2dp") }
        func deactivate() { log.add("deactivate") }
    }

    /// Reconocedor que lanza (formato/engine) o se interrumpe tras un parcial.
    final class Recognizer: SpeechRecognitionPort, @unchecked Sendable {
        let log: Log
        let error: Error?
        let interruptAfter: String?
        init(_ log: Log, error: Error? = nil, interruptAfter: String? = nil) {
            self.log = log
            self.error = error
            self.interruptAfter = interruptAfter
        }
        func start(onPartial: @escaping @Sendable (String) -> Void) throws {
            try start(onPartial: onPartial, onInterrupted: { _ in })
        }
        func start(onPartial: @escaping @Sendable (String) -> Void,
                   onInterrupted: @escaping @Sendable (String) -> Void) throws {
            if let error { throw error }
            log.add("start")
            if let text = interruptAfter {
                onPartial(text)
                onInterrupted("cambio de ruta")
            }
        }
        func stop() { log.add("stop") }
    }

    /// Solo implementa el `start` corto: prueba el default del protocolo.
    final class LegacyRecognizer: SpeechRecognitionPort, @unchecked Sendable {
        let started = Locked(0)
        func start(onPartial: @escaping @Sendable (String) -> Void) throws { started.mutate { $0 += 1 } }
        func stop() {}
    }

    static func loop(_ audio: Audio, diagnostics: GlassesDiagnostics? = nil, silence: TimeInterval = 60) -> VoiceCaptureLoop {
        VoiceCaptureLoop(audio: audio, detector: TurnEndDetector(silence: silence, maxDuration: 60),
                         settle: 0, poll: 0.005, diagnostics: diagnostics)
    }

    @Test func formatoInvalidoNoInstalaTap() {
        #expect(throws: VoiceCaptureFailure.microphoneUnavailable(route: nil, detail: "formato inválido 0 Hz · 1 ch")) {
            try AudioInputFormatGuard.check(sampleRate: 0, channels: 1)
        }
        #expect(throws: VoiceCaptureFailure.self) { try AudioInputFormatGuard.check(sampleRate: 8000, channels: 0) }
        #expect(throws: VoiceCaptureFailure.microphoneUnavailable(route: nil,
                                                                 detail: "formato inconsistente 8000 ≠ 48000 Hz")) {
            try AudioInputFormatGuard.check(sampleRate: 8000, channels: 1, outputSampleRate: 48000)
        }
        #expect(throws: Never.self) { try AudioInputFormatGuard.check(sampleRate: 8000, channels: 1) }
        #expect(throws: Never.self) { try AudioInputFormatGuard.check(sampleRate: 48000, channels: 2, outputSampleRate: 48000) }
    }

    @Test func micDeLasGafasSinFormatoEsErrorVisibleYVuelveAA2DP() async {
        let log = Log()
        let diag = GlassesDiagnostics()
        let failures = Locked<[VoiceCaptureFailure]>([])
        let bad = VoiceCaptureFailure.microphoneUnavailable(route: nil, detail: "formato inválido 0 Hz · 0 ch")
        let result = await Self.loop(Audio(log), diagnostics: diag).run(
            resolve: { .success(Recognizer(log, error: bad)) }, onRoute: { _ in },
            onFailure: { f in failures.mutate { $0.append(f) } })
        #expect(result == nil)
        #expect(log.entries.value == ["hfp", "stop", "deactivate", "a2dp"])
        let failure = failures.value.first
        #expect(failure == .microphoneUnavailable(route: .glassesHFP, detail: "formato inválido 0 Hz · 0 ch"))
        #expect(failure?.message == "Mic de las gafas no disponible. Reintenta.")
        #expect(diag.entries.contains { $0.message.hasPrefix("ruta glassesHFP · settle 0 ms") })
        #expect(diag.entries.contains { $0.message.hasPrefix("sin tap:") })
    }

    @Test func micDelTelefonoSinFormatoDiceTelefono() async {
        let log = Log()
        let failures = Locked<[VoiceCaptureFailure]>([])
        let bad = VoiceCaptureFailure.microphoneUnavailable(route: nil, detail: "x")
        _ = await Self.loop(Audio(log, hfp: false)).run(
            resolve: { .success(Recognizer(log, error: bad)) }, onRoute: { _ in },
            onFailure: { f in failures.mutate { $0.append(f) } })
        #expect(failures.value.first?.message == "Mic del teléfono no disponible. Reintenta.")
        #expect(log.entries.value == ["phoneMic", "stop", "deactivate", "a2dp"])
    }

    @Test func engineQueNoArrancaEsEngineFailed() async {
        let log = Log()
        let failures = Locked<[VoiceCaptureFailure]>([])
        _ = await Self.loop(Audio(log)).run(
            resolve: { .success(Recognizer(log, error: MockError("-10868"))) }, onRoute: { _ in },
            onFailure: { f in failures.mutate { $0.append(f) } })
        #expect(failures.value == [.engineFailed("-10868")])
        #expect(failures.value.first?.message == "No pude usar el micrófono (-10868).")
    }

    @Test func sinPermisosNoSeTocaElAudioYSeDiceLaCausa() async {
        for reason in [VoiceCaptureFailure.microphonePermissionDenied, .speechPermissionDenied,
                       .recognizerUnavailable("sin dictado")] {
            let log = Log()
            let failures = Locked<[VoiceCaptureFailure]>([])
            let routes = Locked(0)
            let result = await Self.loop(Audio(log)).run(
                resolve: { .failure(reason) }, onRoute: { _ in routes.mutate { $0 += 1 } },
                onFailure: { f in failures.mutate { $0.append(f) } })
            #expect(result == nil)
            #expect(log.entries.value.isEmpty)
            #expect(routes.value == 0)
            #expect(failures.value == [reason])
        }
    }

    @Test func cambioDeRutaAMitadTerminaLimpioConservandoLoOido() async {
        let log = Log()
        let result = await Self.loop(Audio(log)).run(
            resolve: { .success(Recognizer(log, interruptAfter: "qué tengo hoy")) }, onRoute: { _ in })
        #expect(result == "qué tengo hoy")
        #expect(log.entries.value == ["hfp", "start", "stop", "deactivate", "a2dp"])
    }

    @Test func elStartLargoPorDefectoDelegaAlCorto() throws {
        let legacy = LegacyRecognizer()
        try legacy.start(onPartial: { _ in }, onInterrupted: { _ in })
        #expect(legacy.started.value == 1)
    }

    @Test func settleReportaEsperaEIntentos() async {
        final class SlowAudio: AudioSessionPort, @unchecked Sendable {
            let clock = Locked<TimeInterval>(0)
            func hfpInputAvailable() -> Bool { true }
            func activateHFP() throws {}
            func currentInputIsHFP() -> Bool { clock.value >= 0.5 }
            func activatePhoneMic() throws {}
            func activatePlaybackA2DP() throws {}
            func deactivate() {}
        }
        let audio = SlowAudio()
        let settled = await AudioRoutePlanner.settle(audio, settle: 2, poll: 0.1, sleep: { s in audio.clock.mutate { $0 += s } })
        #expect(settled.route == .glassesHFP)
        #expect(settled.attempts == 1)
        #expect(settled.hfpAvailable)
        #expect(abs(settled.waited - 0.5) < 0.01)
        let none = await AudioRoutePlanner.settle(Audio(Log(), hfp: false), sleep: { _ in })
        #expect(none == RouteSettlement(route: .phoneMic, waited: 0, attempts: 0, hfpAvailable: false))
    }

    @Test func mensajesYDescripcionesDeCadaCausa() {
        let all: [VoiceCaptureFailure] = [.speechPermissionDenied, .microphonePermissionDenied,
                                          .recognizerUnavailable("r"), .microphoneUnavailable(route: nil, detail: "d"),
                                          .engineFailed("e")]
        #expect(Set(all.map(\.message)).count == all.count)
        #expect(Set(all.map(\.description)).count == all.count)
        #expect(VoiceCaptureFailure.microphoneUnavailable(route: nil, detail: "d").message.contains("gafas"))
        #expect(VoiceCaptureFailure.heading == "No pude usar el micrófono.")
    }

    @Test func elDefaultDeLaCapturaConFalloDelega() async {
        #expect(await SilentVoice().capture(onRoute: { _ in }, onPartial: { _ in }, onFailure: { _ in }) == nil)
    }
}

@Suite("Campo — HUD: 'No pude usar el micrófono' en vez de nada")
@MainActor
struct GlassesVoiceScreenTests {

    @Test func estadoListeningConFalloMuestraLaCausaYVuelve() {
        typealias S = HUDConversationState
        let r = HUDStateMachine.reduce(S(screen: .listening(viaPhone: false)), .voiceFailed("Mic de las gafas no disponible. Reintenta."))
        #expect(r.state.screen == .trouble(heading: VoiceCaptureFailure.heading, message: "Mic de las gafas no disponible. Reintenta."))
        #expect(r.effects == [.returnHomeLater])
        #expect(HUDStateMachine.reduce(S(), .voiceFailed("x")).state == S())
    }

    @Test func laSuperficieMuestraElFalloYVuelveSolaAlHome() async throws {
        let runtime = MockRuntime()
        let body = await readyBody(runtime)
        try await body.ensureActive()
        _ = await body.waitUntilActive()
        let voice = MockVoice()
        voice.failure.mutate { $0 = .microphonePermissionDenied }
        let surface = GlassesHUDSurface(body: body, runner: MockRunner(), sessionId: "s", voice: voice, speech: voice,
                                        errorDwell: 0.1)
        await surface.start()
        await surface.handle(.action(.talk))
        let failed = HUDScreen.trouble(heading: VoiceCaptureFailure.heading,
                                       message: VoiceCaptureFailure.microphonePermissionDenied.message)
        #expect(await eventually { await surface.state.screen == failed })
        let view = HUDRenderer.render(failed)
        try HUDValidator.validate(view)
        #expect(await eventually { await surface.state.screen == .home(status: nil) })
        surface.stop()
    }
}
