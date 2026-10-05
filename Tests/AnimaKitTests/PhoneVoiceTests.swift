import Foundation
import Testing
@testable import AnimaKit

// Campo #9: el mic del composer mostraba "Disponible pronto". Ahora usa el
// pipeline de voz de las gafas forzado al micrófono del TELÉFONO.

/// Voz del composer guionada: emite parciales y espera "Listo"/cancel/fin.
final class ScriptedPhoneVoice: VoiceCapturePort, @unchecked Sendable {
    let result = Locked<String?>(nil)
    let partials = Locked<[String]>([])
    let holdUntilSignal = Locked(false)
    let cancels = Locked(0)
    let finishes = Locked(0)
    private let signalled = Locked(false)

    func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void) async -> String? {
        await capture(onRoute: onRoute, onPartial: { _ in })
    }
    func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void,
                 onPartial: @escaping @Sendable (String) -> Void) async -> String? {
        signalled.mutate { $0 = false }
        onRoute(.phoneMic)
        for p in partials.value { onPartial(p) }
        while holdUntilSignal.value && !signalled.value { try? await Task.sleep(nanoseconds: 2_000_000) }
        return cancels.value > 0 ? nil : result.value
    }
    func cancel() { cancels.mutate { $0 += 1 }; signalled.mutate { $0 = true } }
    func finish() { finishes.mutate { $0 += 1 }; signalled.mutate { $0 = true } }
}

final class HelloRecognizer: SpeechRecognitionPort, @unchecked Sendable {
    func start(onPartial: @escaping @Sendable (String) -> Void) throws { onPartial(" hola anima ") }
    func stop() {}
}

final class QuietAudio: AudioSessionPort, @unchecked Sendable {
    func hfpInputAvailable() -> Bool { false }
    func activateHFP() throws {}
    func currentInputIsHFP() -> Bool { false }
    func activatePhoneMic() throws {}
    func activatePlaybackA2DP() throws {}
    func deactivate() {}
}

@Suite("Campo — mic del composer (voz por el teléfono)")
@MainActor
struct PhoneVoiceTests {

    static func chat(_ provider: CapturingProvider) throws -> (ChatViewModel, SymbolicStore, SessionID) {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [], serverTools: [], sleep: { _ in })
        let sid = try store.startSession()
        return (ChatViewModel(loop: loop, sessionId: sid), store, sid)
    }

    @Test func transcriptSeEnviaComoTurnoDeVozMarcado() async throws {
        let provider = CapturingProvider([.text("Te escuché.")])
        let (chat, _, _) = try Self.chat(provider)
        let voice = ScriptedPhoneVoice()
        voice.result.mutate { $0 = "qué tengo mañana" }
        voice.partials.mutate { $0 = ["qué tengo"] }
        voice.holdUntilSignal.mutate { $0 = true }
        chat.voice = voice

        chat.startVoice()
        #expect(chat.isListening)
        #expect(await eventually { await chat.liveTranscript == "qué tengo" })
        chat.finishVoice()   // "Listo"
        #expect(await eventually { await MainActor.run { chat.messages.count == 2 && chat.messages.last?.isStreaming == false } })
        #expect(!chat.isListening)
        #expect(voice.finishes.value == 1)
        let user = try #require(chat.messages.first)
        #expect(user.text == "qué tengo mañana"); #expect(user.isVoice)
        #expect(chat.messages.last?.text == "Te escuché.")
        // Mismo AgentLoop/sesión, con el prefijo de transcript (igual que las gafas).
        let sent = try #require(provider.captures.value.first?.messages.last { $0.role == .user })
        #expect(sent.content == [AudioTool.transcriptBlock("qué tengo mañana")])
    }

    @Test func cancelarYVacioNoEnvian() async throws {
        let provider = CapturingProvider([.text("no debería")])
        let (chat, _, _) = try Self.chat(provider)
        let voice = ScriptedPhoneVoice()
        voice.result.mutate { $0 = "algo" }
        voice.holdUntilSignal.mutate { $0 = true }
        chat.voice = voice

        chat.startVoice()
        chat.startVoice()   // idempotente mientras escucha
        chat.cancelVoice()  // X / tap fuera
        #expect(!chat.isListening)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(chat.messages.isEmpty)

        // Silencio sin habla: transcript vacío → nada.
        let quiet = ScriptedPhoneVoice()
        quiet.result.mutate { $0 = "   " }
        chat.voice = quiet
        chat.startVoice()
        #expect(await eventually { await !chat.isListening })
        #expect(chat.messages.isEmpty)
        #expect(provider.captures.value.isEmpty)
        // Sin puerto de voz, el mic no arranca; finish/cancel fuera de escucha no hacen nada.
        chat.voice = nil
        chat.startVoice()
        chat.finishVoice()
        chat.cancelVoice()
        #expect(!chat.isListening)
    }

    @Test func micDelTelefonoNuncaTocaHFP() async {
        final class Audio: AudioSessionPort, @unchecked Sendable {
            let calls = Locked<[String]>([])
            func hfpInputAvailable() -> Bool { true }   // gafas conectadas…
            func activateHFP() throws { calls.mutate { $0.append("hfp") } }
            func currentInputIsHFP() -> Bool { true }
            func activatePhoneMic() throws { calls.mutate { $0.append("phoneMic") } }
            func activatePlaybackA2DP() throws { calls.mutate { $0.append("a2dp") } }
            func deactivate() { calls.mutate { $0.append("off") } }
        }
        let audio = Audio()
        let phone = PhoneMicAudioSession(audio)
        #expect(await AudioRoutePlanner.settleCapture(phone, sleep: { _ in }) == .phoneMic)
        #expect(audio.calls.value == ["phoneMic"])   // …y aun así, el mic del teléfono
        try? phone.activateHFP()
        try? phone.activatePlaybackA2DP()
        phone.deactivate()
        #expect(!phone.currentInputIsHFP())
        #expect(audio.calls.value == ["phoneMic", "phoneMic", "a2dp", "off"])
    }

    @Test nonisolated func listoCortaLaEscuchaConservandoLoOido() async {
        // Silencio largo: sin "Listo" no terminaría pronto.
        let loop = VoiceCaptureLoop(audio: QuietAudio(), detector: TurnEndDetector(silence: 60, maxDuration: 60),
                                    settle: 0, poll: 0.005)
        let partials = Locked<[String]>([])
        let task = Task { await loop.run(recognizer: { HelloRecognizer() }, onRoute: { _ in },
                                         onPartial: { p in partials.mutate { $0.append(p) } }) }
        _ = await eventually { !partials.value.isEmpty }
        loop.finish()
        #expect(await task.value == "hola anima")
        #expect(partials.value == ["hola anima"])
        // Los dobles sin voz real usan los defaults del protocolo.
        #expect(await SilentVoice().capture(onRoute: { _ in }, onPartial: { _ in }) == nil)
        SilentVoice().finish()
    }
}
