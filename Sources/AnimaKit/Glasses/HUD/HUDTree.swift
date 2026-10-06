// HUDTree.swift — el vocabulario CERRADO del HUD de Meta Ray-Ban Display (DAT SDK
// 1.0.0) como DATOS puros. Espejo 1:1 del `.swiftinterface` de MWDATDisplay
// (re-verificado contra el checkout 1.0.0; sin cambios de componentes vs 0.9.0
// salvo `Button.actionRole(.primary)`, aún no modelado): 7 componentes, enums exactos.
// El renderer produce estos árboles; el adapter del app shell (App/Glasses) los
// traduce a FlexBox/Text/Icon/Button/ButtonGroup/Image reales. Así el HUD es
// testeable sin hardware y NINGÚN árbol fuera del vocabulario puede existir.
//
// Doc 06 §2: FlexBox (único contenedor, background .none|.card, onTap) · Text
// (3 estilos × 2 colores) · Icon (catálogo cerrado) · Image (uri, .icon|.fill,
// .none|.small|.medium) · Button (.primary|.secondary|.outline, icono opcional)
// · ButtonGroup (solo Buttons, sin padding). VideoPlayer no se usa en Anima.

import Foundation

/// Identificador de una acción del HUD (el callback `onClick`/`onTap` del SDK).
/// El árbol lleva IDs, no closures: el adapter los convierte en eventos.
public struct HUDActionID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public enum HUDTextStyle: String, Sendable, Equatable, CaseIterable { case heading, body, meta }
public enum HUDTextColor: String, Sendable, Equatable, CaseIterable { case primary, secondary }
public enum HUDButtonStyle: String, Sendable, Equatable, CaseIterable { case primary, secondary, outline }
public enum HUDIconStyle: String, Sendable, Equatable, CaseIterable { case filled, outline }
public enum HUDImageSize: String, Sendable, Equatable, CaseIterable { case icon, fill }
public enum HUDCornerRadius: String, Sendable, Equatable, CaseIterable { case none, small, medium }
public enum HUDDirection: String, Sendable, Equatable, CaseIterable { case column, row, columnReverse, rowReverse }
public enum HUDAlignment: String, Sendable, Equatable, CaseIterable { case start, center, end, stretch }
public enum HUDBackground: String, Sendable, Equatable, CaseIterable { case none, card }
public enum HUDButtonGroupAlignment: String, Sendable, Equatable, CaseIterable { case start, center, end }

/// Catálogo `IconName` del SDK 1.0.0 — CERRADO (116 glyphs, idéntico a 0.9.0; diff del .swiftinterface). No hay `mic`,
/// `inbox` ni `github`; "warning" es `exclamationTriangle`. rawValue = el nombre
/// del case del SDK; el adapter mapea con un `switch` exhaustivo (sin fallback).
/// Cómo se PINTA cada uno en las gafas lo decide `HUDIconPolicy`.
public enum HUDIcon: String, Sendable, Equatable, CaseIterable {
    case airplane, arrowDownShallowU, arrowLeft, arrowRight, arrowULeft, arrowUpShallowU, avatar, avatarOff
    case bedSide, bell, bellDiagonalRightDot, bellOff, bikeShare, bug, bullhorn, bus
    case calendar, campfire, caretDown, caretLeft, caretRight, caretUp, carFrontView, cart
    case checkmark, checkmarkCircle, circle8RaysLarge, circleHandle, clock, cloud, cloudCrescentMoon
    case cloudDotFourRays, cloudFiveDashes, cloudHookSwirl, cloudLightning, cocktailGlass, code
    case coffeeCup, compassNorthUpRed, containerWithLid, crossBriefcase, dropper, envelopeOpen
    case exclamationCircle, exclamationTriangle, eye, forkKnife, fourArcsUpFilled
    case fourArcsUpGrayscale, fourCornerFrame, gear, globeWesternHemisphere, graduationCap, hashtag
    case headphones, heart, house, iCircle, lightBulb, magicWand, metaAi, mountainSquare
    case mountainSquareStacked, museumBuilding, musicNote, nineSquaresGrid, padlockClosed
    case padlockOpen, palette, paperAirplane, pencil, pencilSquare, person, personCircle, phone
    case phoneHandsetArrowDownLeft, phoneHandsetArrowUpRight, phoneSlash, pizzaSlice, plus
    case plusCircle, shoppingBag, slidersHorizontal, smartGlasses, smileyCircle, speakerOff
    case speakerWithOneArc, speakerWithThreeArcs, speakerWithTwoArcs, speechBubble, speechBubbleOff
    case stadium, star, starCircleTriangleAi, taxi, threeDotsHorizontal, threeDotSpeechBubble
    case threeHorizontalLines, threeHorizontalLinesStackedDescending, threePeopleOverlapping, train
    case tree, triangleLeftVerticalLine, triangleRight, triangleRightCircle
    case triangleRightVerticalLine, twoArrowsClockwise, twoLinesParallel
    case twoSquaresStackedRightDown, twoTrianglesLeft, twoTrianglesRight, videoCamera
    case videoCameraOff, wristband, wristbandSlash, x
}

public struct HUDText: Sendable, Equatable {
    public var content: String
    public var style: HUDTextStyle
    public var color: HUDTextColor
    public init(_ content: String, style: HUDTextStyle = .body, color: HUDTextColor = .primary) {
        self.content = content
        self.style = style
        self.color = color
    }
}

public struct HUDIconNode: Sendable, Equatable {
    public var name: HUDIcon
    public var style: HUDIconStyle
    /// Camino de render forzado (card de diagnóstico). nil = `HUDIconPolicy.mode`.
    public var path: HUDIconPath?
    public init(_ name: HUDIcon, style: HUDIconStyle = .outline, path: HUDIconPath? = nil) {
        self.name = name
        self.style = style
        self.path = path
    }
}

public struct HUDImage: Sendable, Equatable {
    public var uri: String
    public var size: HUDImageSize
    public var cornerRadius: HUDCornerRadius
    public init(uri: String, size: HUDImageSize = .icon, cornerRadius: HUDCornerRadius = .none) {
        self.uri = uri
        self.size = size
        self.cornerRadius = cornerRadius
    }
}

public struct HUDButton: Sendable, Equatable {
    public var label: String
    public var style: HUDButtonStyle
    public var icon: HUDIcon?
    public var action: HUDActionID
    /// DAT 1.0 `Button.actionRole(.primary)`: el primer botón con este rol recibe
    /// el FOCO al renderizar (menos navegación con captouch). Máximo UNO por vista.
    public var isPrimaryAction: Bool
    public init(_ label: String, style: HUDButtonStyle = .primary, icon: HUDIcon? = nil, action: HUDActionID,
                isPrimaryAction: Bool = false) {
        self.label = label
        self.style = style
        self.icon = icon
        self.action = action
        self.isPrimaryAction = isPrimaryAction
    }
}

public struct HUDButtonGroup: Sendable, Equatable {
    public var alignment: HUDButtonGroupAlignment
    public var buttons: [HUDButton]
    public init(alignment: HUDButtonGroupAlignment = .center, buttons: [HUDButton]) {
        self.alignment = alignment
        self.buttons = buttons
    }
}

public struct HUDFlexBox: Sendable, Equatable {
    public var direction: HUDDirection
    public var spacing: Double
    public var alignment: HUDAlignment
    public var crossAlignment: HUDAlignment
    public var padding: Double?
    public var background: HUDBackground
    public var onTap: HUDActionID?
    public var children: [HUDNode]

    public init(direction: HUDDirection = .column, spacing: Double = 0, alignment: HUDAlignment = .start,
                crossAlignment: HUDAlignment = .start, padding: Double? = nil, background: HUDBackground = .none,
                onTap: HUDActionID? = nil, children: [HUDNode]) {
        self.direction = direction
        self.spacing = spacing
        self.alignment = alignment
        self.crossAlignment = crossAlignment
        self.padding = padding
        self.background = background
        self.onTap = onTap
        self.children = children
    }
}

/// Un nodo del árbol: exactamente los componentes anidables del SDK.
public indirect enum HUDNode: Sendable, Equatable {
    case flexBox(HUDFlexBox)
    case text(HUDText)
    case icon(HUDIconNode)
    case image(HUDImage)
    case button(HUDButton)
    case buttonGroup(HUDButtonGroup)
}

/// Una vista completa del HUD: el root SIEMPRE es un FlexBox (regla 5: cada
/// `send()` reemplaza toda la vista). `isRoot` = vista raíz (sin botón Atrás).
public struct HUDView: Sendable, Equatable {
    public var name: String
    public var root: HUDFlexBox
    public var isRoot: Bool

    public init(name: String, root: HUDFlexBox, isRoot: Bool = false) {
        self.name = name
        self.root = root
        self.isRoot = isRoot
    }

    /// Todos los nodos del árbol en pre-orden (root incluido como flexBox).
    public var allNodes: [HUDNode] {
        var out: [HUDNode] = []
        func walk(_ node: HUDNode) {
            out.append(node)
            switch node {
            case .flexBox(let box): box.children.forEach(walk)
            case .buttonGroup(let group): group.buttons.forEach { out.append(.button($0)) }
            default: break
            }
        }
        walk(.flexBox(root))
        return out
    }

    /// Todos los botones (sueltos o en ButtonGroup).
    public var buttons: [HUDButton] {
        allNodes.compactMap { if case .button(let b) = $0 { return b } else { return nil } }
    }

    /// Todas las acciones interactivas (botones + FlexBox con onTap).
    public var actions: [HUDActionID] {
        allNodes.compactMap { node in
            switch node {
            case .button(let b): return b.action
            case .flexBox(let f): return f.onTap
            default: return nil
            }
        }
    }

    /// Todos los textos (para asserts y presupuesto).
    public var texts: [HUDText] {
        allNodes.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
    }
}
