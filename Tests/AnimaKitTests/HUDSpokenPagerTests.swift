import Foundation
import Testing
@testable import AnimaKit

// Campo #3: la card se cortaba con "…" y no seguía al TTS. Karaoke por ventana.

@Suite("Campo — karaoke por ventana (HUDSpokenPager)")
struct HUDSpokenPagerTests {

    static let long = "Mañana tienes el standup a las nueve con el equipo de producto. "
        + "Después hay una revisión de diseño que suele alargarse, así que bloqueé media hora extra. "
        + "Al mediodía almuerzas con Ana en el sitio de siempre. "
        + "En la tarde no hay reuniones, pero vence el informe trimestral y tienes dos recordatorios pendientes. "
        + "Si quieres, muevo la revisión de diseño al jueves para liberar la mañana. "
        + "También te recuerdo que el viernes es el cumpleaños de tu hermana."

    static func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    @Test func textoCortoEsUnaVentanaIdentica() {
        let text = "Libre de 3:00 a 4:30."
        let pager = HUDSpokenPager(text)
        #expect(pager.windows == [text])
        #expect(pager.window == text)
        #expect(HUDSpokenPager("").windows.isEmpty)
        #expect(HUDSpokenPager("   ").window == "")
    }

    @Test func textoLargoGeneraVentanasEnOrdenConCortesLimpios() {
        let pager = HUDSpokenPager(Self.long)
        let windows = pager.windows
        #expect(windows.count >= 3)
        for (i, w) in windows.enumerated() {
            #expect(w.count <= HUDValidator.bodyLimit)
            #expect(w.hasPrefix("…") == (i > 0))   // "…" solo al inicio si hay texto anterior
            #expect(!w.hasSuffix("…"))
            #expect(w == w.trimmingCharacters(in: .whitespaces))
        }
        // Concatenadas (sin los "…") reconstruyen el texto: nada se pierde ni se repite.
        let rebuilt = windows.map { $0.hasPrefix("…") ? String($0.dropFirst()) : $0 }.joined(separator: " ")
        #expect(rebuilt == Self.long.trimmingCharacters(in: .whitespaces))
        // Corte por oración: la primera ventana termina en un fin de frase.
        #expect(windows[0].hasSuffix("."))
        // Las ventanas cubren rangos consecutivos.
        for (a, b) in zip(pager.pages, pager.pages.dropFirst()) {
            #expect(NSMaxRange(a.range) < b.range.location)
        }
    }

    @Test func corteDePalabraCuandoNoHayFinDeFrase() {
        let text = String(repeating: "palabra ", count: 60).trimmingCharacters(in: .whitespaces)
        let windows = HUDSpokenPager(text, budget: 50).windows
        #expect(windows.count > 1)
        for w in windows {
            let bare = w.hasPrefix("…") ? String(w.dropFirst()) : w
            #expect(bare.split(separator: " ").allSatisfy { $0 == "palabra" })   // ninguna palabra partida
            #expect(w.count <= 50)
        }
        // Sin espacios: corte a la fuerza, sin perder caracteres.
        let blob = String(repeating: "x", count: 30)
        let hard = HUDSpokenPager(blob, budget: 12).windows
        #expect(hard.map { $0.replacingOccurrences(of: "…", with: "") }.joined() == blob)
    }

    @Test func histeresisSoloCambiaAlSalirDeLaVentana() {
        var pager = HUDSpokenPager(Self.long)
        let first = pager.pages[0].range
        // Palabras dentro de la ventana 0: no re-pagina.
        #expect(pager.advance(to: NSRange(location: 0, length: 6)) == nil)
        #expect(pager.advance(to: NSRange(location: NSMaxRange(first) - 3, length: 2)) == nil)
        // La siguiente palabra cae en la ventana 1: cambia UNA vez.
        let second = pager.pages[1].range
        #expect(pager.advance(to: NSRange(location: second.location, length: 4)) == pager.windows[1])
        #expect(pager.advance(to: NSRange(location: second.location + 10, length: 4)) == nil)
        #expect(pager.current == 1)
        // Salto a la última ventana.
        let last = pager.pages[pager.pages.count - 1].range
        #expect(pager.advance(to: NSRange(location: NSMaxRange(last) - 1, length: 1)) == pager.windows.last)
        #expect(pager.advance(to: NSRange(location: NSNotFound, length: 0)) == nil)
    }

    @Test func saltaElTituloQueYaEstaEnPantalla() {
        let text = "Mañana: standup a las 9. Almuerzo con Ana a la 1."
        let pager = HUDSpokenPager(text, after: "Mañana: standup a las 9.")
        #expect(pager.windows == ["Almuerzo con Ana a la 1."])
        #expect(HUDSpokenPager("Solo el título.", after: "Solo el título.").window == "")
        // Título recortado ("…"): no es prefijo, se pagina desde el inicio.
        #expect(HUDSpokenPager("Una frase.", after: "Una…").windows == ["Una frase."])
    }

    @Test func laCardInicialEsLaPrimeraVentana() {
        let reply = "Tu día. " + Self.long
        let r = HUDStateMachine.reduce(HUDConversationState(screen: .thinking(question: "q")), .turnFinished(reply: reply))
        guard case .speaking(let card) = r.state.screen else { Issue.record("no speaking"); return }
        let spoken = HUDSummary.spoken(from: reply)
        #expect(card.heading == "Tu día.")
        #expect(card.body == HUDSpokenPager(spoken, after: "Tu día.").window)
        #expect(!card.body.hasSuffix("…"))
        // La ventana nueva reemplaza el body; al terminar queda la ÚLTIMA.
        let moved = HUDStateMachine.reduce(r.state, .speechWindow("…ventana final."))
        #expect(moved.state.screen == .speaking(HUDCard(heading: card.heading, body: "…ventana final.", overflow: card.overflow)))
        #expect(moved.effects.isEmpty)
        let done = HUDStateMachine.reduce(moved.state, .speechFinished)
        guard case .answer(let final) = done.state.screen else { Issue.record("no answer"); return }
        #expect(final.body == "…ventana final.")
        try? HUDValidator.validate(HUDRenderer.render(done.state.screen))
        // Fuera de speaking la ventana no hace nada.
        #expect(HUDStateMachine.reduce(HUDConversationState(), .speechWindow("x")).state == HUDConversationState())
    }
}

@Suite("Campo — la superficie re-envía solo al cambiar de ventana")
@MainActor
struct GlassesKaraokeTests {

    @Test func reEnviaExactamenteCuandoCambiaLaVentana() async throws {
        let rig = await GlassesRig.make()
        let reply = "Tu día. " + HUDSpokenPagerTests.long
        let spoken = HUDSummary.spoken(from: reply)
        let pager = HUDSpokenPager(spoken, after: "Tu día.")
        #expect(pager.pages.count >= 2)   // TTS acotado a 280 + remisión al teléfono
        rig.voice.wordRanges.mutate { $0 = true }   // rango por palabra, POR utterance
        rig.runner.replies.mutate { $0 = [GlassesConversationTests.reply(reply)] }

        await rig.surface.handle(.action(.talk))
        await rig.surface.handle(.transcript("¿qué tengo mañana?"))
        let before = rig.display?.sent.value.count ?? 0
        await rig.surface.handle(.action(.send))
        #expect(await eventually { if case .answer = await rig.surface.state.screen { return true } else { return false } })

        // Lo hablado = las utterances encoladas por oración (mismo texto que el resumen).
        #expect(rig.voice.spoken.value.joined(separator: " ") == spoken)
        let sent = Array(rig.display?.sent.value.dropFirst(before) ?? [])
        let speaking = sent.filter { $0.name == "speaking" }
        let bodies = speaking.compactMap { $0.texts.first { $0.style == .body }?.content }
        // Cada envío es un cambio real de ventana (nunca dos iguales seguidos)…
        for (a, b) in zip(bodies, bodies.dropFirst()) { #expect(a != b) }
        // …las ventanas del texto completo aparecen en orden…
        var cursor = bodies.startIndex
        for window in pager.windows {
            guard let hit = bodies[cursor...].firstIndex(of: window) else { Issue.record("falta \(window)"); break }
            cursor = hit + 1
        }
        // …y no hay re-render por palabra: a lo sumo una página extra (la que crece con el stream).
        let words = spoken.split(separator: " ").count
        #expect(speaking.count <= pager.pages.count + 1)
        #expect(speaking.count < words / 4)
        for view in sent { try HUDValidator.validate(view) }
        // Done: la card queda con la última ventana + los botones de siempre.
        let answer = try #require(rig.lastView)
        #expect(answer.name == "answer")
        #expect(answer.texts.contains { $0.content == pager.windows.last })
        #expect(answer.buttons.map(\.action).contains(.reply))
        #expect(answer.buttons.map(\.action).contains(.onPhone))
    }

    @Test func progresoDeOtroTurnoSeIgnora() async throws {
        let rig = await GlassesRig.make()
        await rig.surface.spoke(0, NSRange(location: 400, length: 2), generation: 99)
        #expect(rig.surface.state.screen == .home(status: nil))
    }
}
