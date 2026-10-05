import Foundation
import Testing
@testable import AnimaKit

// Campo #7b: el TTS esperaba la respuesta COMPLETA. Ahora dice la primera
// oración apenas llega del stream y encola las siguientes.

@Suite("Campo — TTS por oración del stream")
struct SpokenStreamTests {

    @Test func segmentadorEmiteOracionesCompletasUnaVez() {
        var seg = StreamingSentenceSegmenter()
        #expect(seg.feed("Mañana: stand").isEmpty)
        #expect(seg.feed("up a las 9.").isEmpty)          // sin espacio aún: puede ser "9.30"
        #expect(seg.feed("30. Almuerzo") == ["Mañana: standup a las 9.30."])
        #expect(seg.feed(" con **Ana**? ¡Sí! Y") == ["Almuerzo con Ana?", "¡Sí!"])
        #expect(seg.feed("").isEmpty)
        #expect(seg.finish() == ["Y"])
        #expect(seg.finish().isEmpty)
        // Markdown y saltos de línea: texto plano para la voz.
        var md = StreamingSentenceSegmenter()
        #expect(md.feed("# Agenda\n- **9:00** standup.\n- café") == ["Agenda 9:00 standup."])
        #expect(md.finish() == ["café"])
        var empty = StreamingSentenceSegmenter()
        #expect(empty.feed("  \n").isEmpty)
        #expect(empty.finish().isEmpty)
    }

    @Test func guionAplicaElPresupuestoDeVozComoElResumen() {
        let long = String(repeating: "Frase de relleno bastante larga. ", count: 20)
        var script = SpokenScript()
        var said: [String] = []
        for chunk in long.split(separator: " ", omittingEmptySubsequences: false) {
            said += script.feed(String(chunk) + " ")
        }
        said += script.finish()
        #expect(script.truncated)
        #expect(said.last == HUDSummary.phoneTail)
        #expect(script.text == HUDSummary.spoken(from: long))   // misma política que HUDSummary.spoken
        #expect(script.feed("más.").isEmpty)                     // cerrado: nada más
        #expect(script.finish().isEmpty)

        var short = SpokenScript()
        #expect(short.feed("Libre a las 3. Nada") == ["Libre a las 3."])
        #expect(short.finish() == ["Nada"])
        #expect(short.text == HUDSummary.spoken(from: "Libre a las 3. Nada"))

        // Primera oración más larga que el presupuesto: se recorta y remite al teléfono.
        var huge = SpokenScript(limit: 20)
        #expect(huge.feed("Una oración larguísima que no cabe. Otra.") == [HUDSummary.clip("Una oración larguísima que no cabe.", 20)])
        #expect(huge.finish() == [HUDSummary.phoneTail])
    }

    @Test func offsetsDelPagerConVariasUtterances() throws {
        var script = SpokenScript()
        _ = script.feed("Uno dos. Ñandú tres. ")
        _ = script.finish()
        #expect(script.utterances == ["Uno dos.", "Ñandú tres."])
        #expect(script.offset(of: 0) == 0)
        #expect(script.offset(of: 1) == ("Uno dos." as NSString).length + 1)
        // "tres" en la utterance 1 → su rango absoluto en el texto completo.
        let local = ("Ñandú tres." as NSString).range(of: "tres")
        let absolute = script.absolute(1, local)
        #expect((script.text as NSString).substring(with: absolute) == "tres")
        #expect(script.absolute(0, NSRange(location: NSNotFound, length: 0)).location == NSNotFound)
        // El pager sobre el texto completo avanza con los rangos absolutos.
        var pager = HUDSpokenPager(script.text, budget: 10)
        let page = try #require(pager.pages.firstIndex { NSLocationInRange(absolute.location, $0.range) })
        #expect(pager.advance(to: absolute) == pager.windows[page])
        let whole = SpokenScript(whole: "Todo junto.")
        #expect(whole.utterances == ["Todo junto."]); #expect(whole.finished)
        #expect(SpokenScript(whole: "").utterances.isEmpty)
    }
}

/// Runner cuyo stream controla el test (deltas a mano, cierre a mano).
final class GatedRunner: TurnRunner, @unchecked Sendable {
    let continuation = Locked<AsyncStream<LoopEvent>.Continuation?>(nil)
    func run(sessionId: SessionID, content: [ContentBlock], surface: SurfaceID) async -> AsyncStream<LoopEvent> {
        let (stream, cont) = AsyncStream<LoopEvent>.makeStream()
        continuation.mutate { $0 = cont }
        return stream
    }
    func yield(_ e: LoopEvent) { continuation.value?.yield(e) }
    func finish() { continuation.value?.finish() }
}

@Suite("Campo — la primera oración suena antes de que termine el turno")
@MainActor
struct GlassesStreamingSpeechTests {

    static func surface(_ runner: GatedRunner) async -> (GlassesHUDSurface, MockVoice, MockRuntime) {
        let runtime = MockRuntime()
        let body = await readyBody(runtime)
        try? await body.ensureActive()
        _ = await body.waitUntilActive()
        let voice = MockVoice()
        let surface = GlassesHUDSurface(body: body, runner: runner, sessionId: "s", voice: voice, speech: voice)
        await surface.start()
        return (surface, voice, runtime)
    }

    @Test func ttsArrancaConLaPrimeraOracionDelStream() async throws {
        let runner = GatedRunner()
        let (surface, voice, runtime) = await Self.surface(runner)
        await surface.handle(.action(.talk))
        await surface.handle(.transcript("¿qué tengo mañana?"))
        await surface.handle(.action(.send))
        #expect(await eventually { runner.continuation.value != nil })

        runner.yield(.textDelta("Mañana: standup a las 9. Almuer"))
        // El turno NO ha terminado y la primera oración ya suena; la vista pasa a speaking.
        #expect(await eventually { voice.spoken.value == ["Mañana: standup a las 9."] })
        #expect(await eventually { if case .speaking = await surface.state.screen { return true } else { return false } })
        let speaking = try #require(runtime.lastSession?.display.sent.value.last)
        #expect(speaking.texts.contains { $0.content == "Mañana: standup a las 9." && $0.style == .heading })
        try HUDValidator.validate(speaking)

        runner.yield(.textDelta("zo con Ana. Café a las"))
        #expect(await eventually { voice.spoken.value.count == 2 })
        #expect(voice.spoken.value.last == "Almuerzo con Ana.")
        runner.yield(.textDelta(" 3."))
        runner.yield(.turnFinished(stopReason: .endTurn))
        runner.finish()
        #expect(await eventually { if case .answer = await surface.state.screen { return true } else { return false } })
        #expect(voice.spoken.value == ["Mañana: standup a las 9.", "Almuerzo con Ana.", "Café a las 3."])
        let answer = try #require(runtime.lastSession?.display.sent.value.last)
        #expect(answer.texts.contains { $0.content == "Almuerzo con Ana. Café a las 3." })
        surface.stop()
    }

    @Test func atrasDuranteElStreamCallaYNoVuelveAHablar() async throws {
        let runner = GatedRunner()
        let (surface, voice, _) = await Self.surface(runner)
        await surface.handle(.action(.talk))
        await surface.handle(.transcript("q"))
        await surface.handle(.action(.send))
        #expect(await eventually { runner.continuation.value != nil })
        runner.yield(.textDelta("Primera. Segunda"))
        // Precondición REAL del escenario: la primera oración ya se habló (no solo
        // el estado .speaking — el back podía colarse antes del speak y dejar spoken=[]).
        #expect(await eventually { voice.spoken.value == ["Primera."] })
        await surface.handle(.action(.back))
        #expect(surface.state.screen == .home(status: nil))
        runner.yield(.textDelta(". Tercera. Cuarta."))
        runner.finish()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(voice.spoken.value == ["Primera."])
        #expect(voice.stops.value >= 1)
        surface.stop()
    }

    @Test func rechazoAMitadDeStreamCallaYMuestraElRechazo() async throws {
        let runner = GatedRunner()
        let (surface, voice, _) = await Self.surface(runner)
        await surface.handle(.action(.talk))
        await surface.handle(.transcript("q"))
        await surface.handle(.action(.send))
        #expect(await eventually { runner.continuation.value != nil })
        runner.yield(.textDelta("Mmm. No voy"))
        #expect(await eventually { if case .speaking = await surface.state.screen { return true } else { return false } })
        runner.yield(.refused)
        runner.yield(.textDelta(" a leer eso. Más."))
        runner.finish()
        #expect(await eventually { if case .declined = await surface.state.screen { return true } else { return false } })
        #expect(voice.spoken.value == ["Mmm."])
        surface.stop()
    }

    @Test func cardDelAgenteSoloHablaSinCambiarLaVista() async throws {
        let runner = GatedRunner()
        let (surface, voice, _) = await Self.surface(runner)
        await surface.handle(.action(.talk))
        await surface.handle(.transcript("q"))
        await surface.handle(.action(.send))
        #expect(await eventually { runner.continuation.value != nil })
        let box = HUDFlexBox(background: .card, children: [.text(HUDText("9:00", style: .heading))])
        #expect(await surface.project(box))
        runner.yield(.textDelta("Te lo mostré. Listo"))
        #expect(await eventually { voice.spoken.value == ["Te lo mostré."] })
        runner.finish()
        #expect(await eventually { voice.spoken.value == ["Te lo mostré.", "Listo"] })
        #expect(surface.state.screen == .agentCard(box))
        surface.stop()
    }
}
