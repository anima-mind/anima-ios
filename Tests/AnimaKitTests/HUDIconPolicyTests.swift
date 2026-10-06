import Foundation
import Testing
@testable import AnimaKit

// Campo batch 6: "los iconos no se ven, solo phone y eye". El mapeo HUDIcon →
// IconName es 1:1 (este test lo fija contra el catálogo del .swiftinterface
// 1.0.0); el sol lo pinta el DAT de las gafas. Política: verificados nativos,
// el resto como glifo propio (imagen) o texto; botones sin icono no verificado.

@Suite("Campo — política de iconos del HUD (sol → glifos propios)")
struct HUDIconPolicyTests {

    /// `IconName` del MWDATDisplay 1.0.0 (`.swiftinterface`, enum IconName: String,
    /// 0 raw values explícitos → rawValue == nombre del case).
    static let sdkCatalog: [String] = [
        "airplane", "arrowDownShallowU", "arrowLeft", "arrowRight", "arrowULeft", "arrowUpShallowU", "avatar",
        "avatarOff", "bedSide", "bell", "bellDiagonalRightDot", "bellOff", "bikeShare", "bug", "bullhorn", "bus",
        "calendar", "campfire", "carFrontView", "caretDown", "caretLeft", "caretRight", "caretUp", "cart",
        "checkmark", "checkmarkCircle", "circle8RaysLarge", "circleHandle", "clock", "cloud", "cloudCrescentMoon",
        "cloudDotFourRays", "cloudFiveDashes", "cloudHookSwirl", "cloudLightning", "cocktailGlass", "code",
        "coffeeCup", "compassNorthUpRed", "containerWithLid", "crossBriefcase", "dropper", "envelopeOpen",
        "exclamationCircle", "exclamationTriangle", "eye", "forkKnife", "fourArcsUpFilled", "fourArcsUpGrayscale",
        "fourCornerFrame", "gear", "globeWesternHemisphere", "graduationCap", "hashtag", "headphones", "heart",
        "house", "iCircle", "lightBulb", "magicWand", "metaAi", "mountainSquare", "mountainSquareStacked",
        "museumBuilding", "musicNote", "nineSquaresGrid", "padlockClosed", "padlockOpen", "palette",
        "paperAirplane", "pencil", "pencilSquare", "person", "personCircle", "phone", "phoneHandsetArrowDownLeft",
        "phoneHandsetArrowUpRight", "phoneSlash", "pizzaSlice", "plus", "plusCircle", "shoppingBag",
        "slidersHorizontal", "smartGlasses", "smileyCircle", "speakerOff", "speakerWithOneArc",
        "speakerWithThreeArcs", "speakerWithTwoArcs", "speechBubble", "speechBubbleOff", "stadium", "star",
        "starCircleTriangleAi", "taxi", "threeDotSpeechBubble", "threeDotsHorizontal", "threeHorizontalLines",
        "threeHorizontalLinesStackedDescending", "threePeopleOverlapping", "train", "tree",
        "triangleLeftVerticalLine", "triangleRight", "triangleRightCircle", "triangleRightVerticalLine",
        "twoArrowsClockwise", "twoLinesParallel", "twoSquaresStackedRightDown", "twoTrianglesLeft",
        "twoTrianglesRight", "videoCamera", "videoCameraOff", "wristband", "wristbandSlash", "x",
    ]

    @Test func elCatalogoEsIdenticoAlDelSDK() {
        #expect(Self.sdkCatalog.count == 116)
        #expect(Set(HUDIcon.allCases.map(\.rawValue)) == Set(Self.sdkCatalog))
        #expect(HUDIcon.allCases.count == Self.sdkCatalog.count)
        for name in Self.sdkCatalog { #expect(HUDIcon(rawValue: name) != nil, "\(name)") }
    }

    /// Todos los iconos que el renderer del HUD usa (vistas + botones).
    static var usedIcons: Set<HUDIcon> {
        let card = HUDCard(heading: "h", body: "b")
        let screens: [HUDScreen] = [
            .home(status: nil), .capturing, .listening(viaPhone: false), .listening(viaPhone: true),
            .heard(transcript: "t"), .thinking(question: "q"), .speaking(card), .answer(card), .declined("d"),
            .attention("a"), .cameraConfirm(reason: "r"), .handoff,
        ]
        var icons = Set<HUDIcon>()
        for screen in screens {
            let view = HUDRenderer.render(screen)
            for node in view.allNodes {
                if case .icon(let icon) = node { icons.insert(icon.name) }
            }
            for button in view.buttons { if let icon = button.icon { icons.insert(icon) } }
        }
        return icons
    }

    @Test func cadaIconoUsadoTieneGlifoPropioYTexto() {
        #expect(Self.usedIcons.count >= 10)
        for icon in Self.usedIcons {
            #expect(HUDIconPolicy.symbol(for: icon) != nil, "\(icon) sin SF Symbol")
            #expect(HUDIconPolicy.text(for: icon) != nil, "\(icon) sin glifo de texto")
        }
    }

    @Test func autoNativoSoloLosVerificadosYElRestoImagen() {
        #expect(HUDIconPolicy.verifiedNative == [.phone, .eye])
        #expect(HUDIconPolicy.path(for: .phone, mode: .auto) == .native)
        #expect(HUDIconPolicy.path(for: .eye, mode: .auto) == .native)
        for icon in Self.usedIcons.subtracting(HUDIconPolicy.verifiedNative) {
            #expect(HUDIconPolicy.path(for: icon, mode: .auto) == .image, "\(icon)")
        }
        // Sin SF Symbol conocido cae a texto, nunca al catálogo (sol).
        #expect(HUDIconPolicy.symbol(for: .pizzaSlice) == nil)
        #expect(HUDIconPolicy.path(for: .pizzaSlice, mode: .auto) == .text)
        #expect(HUDIconPolicy.path(for: .pizzaSlice, mode: .image) == .text)
        #expect(HUDIconPolicy.path(for: .arrowLeft, mode: .native) == .native)
        #expect(HUDIconPolicy.path(for: .arrowLeft, mode: .image) == .image)
        #expect(HUDIconPolicy.path(for: .phone, mode: .text) == .text)
    }

    @Test func botonesSinIconoNoVerificadoSalvoModoCatalogo() {
        #expect(HUDIconPolicy.buttonIcon(nil, mode: .native) == nil)
        for mode in [HUDIconMode.auto, .image, .text] {
            #expect(HUDIconPolicy.buttonIcon(.arrowLeft, mode: mode) == nil)
            #expect(HUDIconPolicy.buttonIcon(.paperAirplane, mode: mode) == nil)
            #expect(HUDIconPolicy.buttonIcon(.phone, mode: mode) == .phone)
        }
        #expect(HUDIconPolicy.buttonIcon(.arrowLeft, mode: .native) == .arrowLeft)
        #expect(HUDIconPolicy.buttonLabel("Atrás", icon: .arrowLeft, mode: .text) == "‹ Atrás")
        #expect(HUDIconPolicy.buttonLabel("Atrás", icon: .arrowLeft, mode: .auto) == "Atrás")
        #expect(HUDIconPolicy.buttonLabel("En el teléfono", icon: .phone, mode: .text) == "En el teléfono")
        #expect(HUDIconPolicy.buttonLabel("Listo", icon: nil, mode: .text) == "Listo")
        #expect(HUDIconPolicy.buttonLabel("Pizza", icon: .pizzaSlice, mode: .text) == "Pizza")
    }

    @Test func elModoGlobalSeLeeYSeEscribe() {
        let before = HUDIconPolicy.mode
        defer { HUDIconPolicy.mode = before }
        for mode in HUDIconMode.allCases {
            HUDIconPolicy.mode = mode
            #expect(HUDIconPolicy.mode == mode)
            #expect(!mode.label.isEmpty)
        }
    }

    @Test func cardDeCaminosMuestraLosTresPorIconoYEsValida() throws {
        let box = HUDIconProbe.pathsCard()
        let view = HUDRenderer.render(.agentCard(box))
        try HUDValidator.validate(view)
        let forced = view.allNodes.compactMap { node -> HUDIconNode? in
            if case .icon(let icon) = node { return icon.path == nil ? nil : icon } else { return nil }
        }
        #expect(forced.count == HUDIconProbe.pathSamples.count * HUDIconPath.allCases.count)
        for icon in HUDIconProbe.pathSamples {
            #expect(Set(forced.filter { $0.name == icon }.compactMap(\.path)) == Set(HUDIconPath.allCases))
            #expect(view.texts.contains { $0.content == icon.rawValue })
        }
        #expect(HUDIconPath.allCases.map(HUDIconProbe.pathLabel) == ["M", "I", "T"])
    }
}
