// HUDIconProbe.swift — card de diagnóstico "Probar iconos" (Ajustes → Gafas).
// Campo #2: los iconos de los botones salían todos como el "sol"
// (.circle8RaysLarge, el fallback del adapter) aunque existen en el enum del
// SDK. Sospecha: catálogo parcial del lado del firmware / app DAT. Esta card
// proyecta los candidatos CADA UNO con su nombre al lado, para reportar en
// hardware cuáles renderizan y cuáles caen al sol. Va por el camino normal de
// render (la card del agente: root + Atrás + validador).

import Foundation

public enum HUDIconProbe {
    public static let perCard = 8

    /// Los 5 probados por Relay en hardware, el sol (control), los que usa
    /// Anima, los nuevos de los botones y alternativas para "Foto".
    public static let candidates: [HUDIcon] = [
        .phone, .eye, .magicWand, .speakerWithThreeArcs, .crossBriefcase, .circle8RaysLarge,
        .speechBubble, .checkmarkCircle,
        .paperAirplane, .twoArrowsClockwise, .checkmark, .x, .arrowLeft, .smartGlasses,
        .speakerWithTwoArcs, .speechBubbleOff,
        .exclamationTriangle, .videoCamera, .mountainSquare, .fourCornerFrame, .iCircle, .lightBulb,
        .metaAi, .star,
    ]

    /// Los candidatos partidos en cards de `perCard`.
    public static var pages: [[HUDIcon]] {
        stride(from: 0, to: candidates.count, by: perCard).map {
            Array(candidates[$0..<min($0 + perCard, candidates.count)])
        }
    }

    public static var cardCount: Int { pages.count }

    /// La card `index` (módulo el total): meta "Iconos i/n" + filas de 2 pares icono·nombre.
    public static func card(_ index: Int) -> HUDFlexBox {
        let all = pages
        let i = ((index % all.count) + all.count) % all.count
        let icons = all[i]
        var nodes: [HUDNode] = [
            .text(HUDText("Iconos \(i + 1)/\(all.count) · ¿cuáles salen como sol?", style: .meta, color: .secondary)),
        ]
        for row in stride(from: 0, to: icons.count, by: 2) {
            let pairs = icons[row..<min(row + 2, icons.count)].map { icon in
                HUDNode.flexBox(HUDFlexBox(direction: .row, spacing: 6, crossAlignment: .center, children: [
                    .icon(HUDIconNode(icon, style: .outline)),
                    .text(HUDText(icon.rawValue, style: .meta)),
                ]))
            }
            nodes.append(.flexBox(HUDFlexBox(direction: .row, spacing: 16, crossAlignment: .center, children: pairs)))
        }
        return HUDFlexBox(direction: .column, spacing: 8, padding: 12, background: .card, children: nodes)
    }

    /// Iconos de muestra de la card "Probar caminos" (los que más usa el HUD).
    public static let pathSamples: [HUDIcon] = [.arrowLeft, .x, .checkmarkCircle, .smartGlasses]

    /// Etiqueta corta de cada camino en la card (M = catálogo Meta).
    public static func pathLabel(_ path: HUDIconPath) -> String {
        switch path {
        case .native: return "M"
        case .image: return "I"
        case .text: return "T"
        }
    }

    /// Card "Probar caminos": por icono, el MISMO glifo por los 3 caminos
    /// (catálogo Meta / imagen propia / texto) para reportar cuál se ve.
    public static func pathsCard() -> HUDFlexBox {
        var nodes: [HUDNode] = [
            .text(HUDText("Caminos · M=Meta I=Imagen T=Texto · ¿cuál se ve?", style: .meta, color: .secondary)),
        ]
        for icon in pathSamples {
            var row: [HUDNode] = [.text(HUDText(icon.rawValue, style: .meta))]
            for path in HUDIconPath.allCases {
                row.append(.flexBox(HUDFlexBox(direction: .row, spacing: 4, crossAlignment: .center, children: [
                    .icon(HUDIconNode(icon, style: .outline, path: path)),
                    .text(HUDText(pathLabel(path), style: .meta, color: .secondary)),
                ])))
            }
            nodes.append(.flexBox(HUDFlexBox(direction: .row, spacing: 12, crossAlignment: .center, children: row)))
        }
        return HUDFlexBox(direction: .column, spacing: 8, padding: 12, background: .card, children: nodes)
    }

    /// Los iconos (en orden) y el nombre mostrado al lado de cada uno.
    public static func labeledIcons(in box: HUDFlexBox) -> [(icon: HUDIcon, label: String)] {
        var out: [(HUDIcon, String)] = []
        func walk(_ node: HUDNode) {
            guard case .flexBox(let b) = node else { return }
            if b.children.count == 2, case .icon(let icon) = b.children[0], case .text(let text) = b.children[1] {
                out.append((icon.name, text.content))
                return
            }
            b.children.forEach(walk)
        }
        walk(.flexBox(box))
        return out
    }
}
