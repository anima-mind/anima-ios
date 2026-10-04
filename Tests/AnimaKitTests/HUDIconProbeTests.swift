import Foundation
import Testing
@testable import AnimaKit

// Campo #2: los iconos de los botones salían como "sol". Iconos semánticos en
// los botones + card de diagnóstico con cada icono y su nombre.

@Suite("Campo — iconos de botones y card 'Probar iconos'")
struct HUDIconProbeTests {

    static func icon(_ view: HUDView, _ action: HUDActionID) -> HUDIcon? {
        view.buttons.first { $0.action == action }?.icon
    }

    @Test func botonesConIconosSemanticos() {
        let heard = HUDRenderer.render(.heard(transcript: "hola"))
        #expect(Self.icon(heard, .again) == .twoArrowsClockwise)
        #expect(Self.icon(heard, .send) == .paperAirplane)
        let answer = HUDRenderer.render(.answer(HUDCard(heading: "Listo.", body: "")))
        #expect(Self.icon(answer, .reply) == .speechBubble)
        #expect(Self.icon(answer, .onPhone) == .phone)
    }

    @Test func candidatosIncluyenLosProbadosLosUsadosYLosNuevos() {
        let set = Set(HUDIconProbe.candidates.map(\.rawValue))
        #expect(set.count == HUDIconProbe.candidates.count)   // sin duplicados
        for name in ["phone", "eye", "magicWand", "speakerWithThreeArcs", "crossBriefcase",   // Relay
                     "speechBubble", "checkmarkCircle", "circle8RaysLarge",                    // usados / control
                     "paperAirplane", "twoArrowsClockwise", "checkmark", "x"] {               // nuevos
            #expect(set.contains(name), "\(name)")
        }
        #expect((2...3).contains(HUDIconProbe.cardCount))
    }

    @Test func cadaCardEsValidaYMuestraElRawValue() throws {
        var shown: [HUDIcon] = []
        for i in 0..<HUDIconProbe.cardCount {
            let box = HUDIconProbe.card(i)
            let view = HUDRenderer.render(.agentCard(box))
            try HUDValidator.validate(view)
            let pairs = HUDIconProbe.labeledIcons(in: box)
            #expect(pairs.count <= HUDIconProbe.perCard)
            for pair in pairs { #expect(pair.label == pair.icon.rawValue) }
            #expect(view.texts.contains { $0.content.hasPrefix("Iconos \(i + 1)/\(HUDIconProbe.cardCount)") })
            shown += pairs.map(\.icon)
        }
        #expect(shown == HUDIconProbe.candidates)   // todos, en orden, una vez
        #expect(HUDIconProbe.card(HUDIconProbe.cardCount) == HUDIconProbe.card(0))   // cicla
        #expect(HUDIconProbe.card(-1) == HUDIconProbe.card(HUDIconProbe.cardCount - 1))
    }

    @MainActor
    @Test func laCardSeProyectaPorLaSuperficieNormal() async throws {
        let rig = await GlassesRig.make()
        #expect(await rig.surface.project(HUDIconProbe.card(0)))
        let view = try #require(rig.lastView)
        #expect(view.name == "agentCard")
        try HUDValidator.validate(view)
        #expect(view.texts.contains { $0.content == "paperAirplane" } == false)   // card 1: Relay + control
        #expect(view.texts.contains { $0.content == "magicWand" })
    }
}
