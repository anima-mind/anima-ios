// HUDIconPolicy.swift — CÓMO se pinta cada HUDIcon en las gafas (campo batch 6).
// Hecho verificado: el mapeo HUDIcon → IconName del SDK 1.0.0 es 1:1 (116 = 116,
// test de catálogo), pero en hardware TODOS los glifos del catálogo salían como
// el placeholder "sol" salvo `phone` y `eye`: el DAT de las gafas no conoce esos
// nombres (el SDK los serializa en snake_case: `arrow_left`, `smart_glasses`…).
// No hay SDK > 1.0.0, así que hay que vivir con ello:
//   · `.native`: Icon/IconName del catálogo (solo los verificados en hardware).
//   · `.image`: glifo propio (SF Symbol renderizado a PNG blanco sobre
//     transparente) enviado con `Image(image:sizePreset: .icon)`.
//   · `.text`: glifo unicode dentro de un Text (último recurso).
// Los botones del SDK solo aceptan `IconName`: fuera del catálogo verificado van
// SIN icono (nunca más el sol). El modo es un ajuste del dueño (diagnóstico de
// campo): `auto` = verificados nativos + el resto como imagen.

import Foundation

/// El camino de render de un icono concreto.
public enum HUDIconPath: String, Sendable, Equatable, CaseIterable {
    case native, image, text
}

/// Ajuste global del dueño (Ajustes → Gafas → Íconos).
public enum HUDIconMode: String, Sendable, Equatable, CaseIterable {
    case auto, native, image, text

    public var label: String {
        switch self {
        case .auto: return "Automático"
        case .native: return "Catálogo Meta"
        case .image: return "Imagen"
        case .text: return "Texto"
        }
    }
}

public enum HUDIconPolicy {
    public static let modeKey = "glasses.iconMode"

    /// Glifos del catálogo que SÍ se ven en las gafas (video de campo, batch 6).
    public static let verifiedNative: Set<HUDIcon> = [.phone, .eye]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _mode: HUDIconMode = .auto

    /// Modo vigente (lo lee el adapter en cada render).
    public static var mode: HUDIconMode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); _mode = newValue; lock.unlock() }
    }

    /// Camino de un icono suelto (fila icono·meta de las cards).
    public static func path(for icon: HUDIcon, mode: HUDIconMode) -> HUDIconPath {
        switch mode {
        case .auto: return verifiedNative.contains(icon) ? .native : (symbol(for: icon) != nil ? .image : .text)
        case .native: return .native
        case .image: return symbol(for: icon) != nil ? .image : .text
        case .text: return .text
        }
    }

    /// El icono que se le pasa al `Button` del SDK (solo acepta IconName).
    public static func buttonIcon(_ icon: HUDIcon?, mode: HUDIconMode) -> HUDIcon? {
        guard let icon else { return nil }
        switch mode {
        case .native: return icon
        case .auto, .image, .text: return verifiedNative.contains(icon) ? icon : nil
        }
    }

    /// La etiqueta del botón: en modo texto lleva el glifo unicode delante.
    public static func buttonLabel(_ label: String, icon: HUDIcon?, mode: HUDIconMode) -> String {
        guard mode == .text, let icon, !verifiedNative.contains(icon), let glyph = text(for: icon) else { return label }
        return "\(glyph) \(label)"
    }

    /// SF Symbol del glifo propio (camino `.image`). nil = sin equivalente.
    public static func symbol(for icon: HUDIcon) -> String? {
        switch icon {
        case .arrowLeft: return "chevron.left"
        case .arrowRight: return "chevron.right"
        case .x: return "xmark"
        case .checkmark: return "checkmark"
        case .checkmarkCircle: return "checkmark.circle"
        case .speechBubble: return "bubble.left"
        case .speechBubbleOff: return "bubble.left.and.exclamationmark.bubble.right"
        case .threeDotSpeechBubble: return "ellipsis.bubble"
        case .videoCamera: return "camera"
        case .videoCameraOff: return "video.slash"
        case .paperAirplane: return "paperplane"
        case .twoArrowsClockwise: return "arrow.clockwise"
        case .speakerWithOneArc: return "speaker.wave.1"
        case .speakerWithTwoArcs: return "speaker.wave.2"
        case .speakerWithThreeArcs: return "speaker.wave.3"
        case .speakerOff: return "speaker.slash"
        case .smartGlasses: return "eyeglasses"
        case .exclamationTriangle: return "exclamationmark.triangle"
        case .exclamationCircle: return "exclamationmark.circle"
        case .circle8RaysLarge: return "sparkles"
        case .phone: return "iphone"
        case .eye: return "eye"
        case .bell: return "bell"
        case .calendar: return "calendar"
        case .clock: return "clock"
        case .gear: return "gearshape"
        case .heart: return "heart"
        case .house: return "house"
        case .iCircle: return "info.circle"
        case .lightBulb: return "lightbulb"
        case .magicWand: return "wand.and.stars"
        case .person: return "person"
        case .star: return "star"
        case .plus: return "plus"
        case .pencil: return "pencil"
        case .musicNote: return "music.note"
        case .mountainSquare: return "photo"
        case .envelopeOpen: return "envelope.open"
        case .padlockClosed: return "lock"
        case .headphones: return "headphones"
        default: return nil
        }
    }

    /// Glifo unicode (camino `.text`). nil = sin equivalente legible.
    public static func text(for icon: HUDIcon) -> String? {
        switch icon {
        case .arrowLeft: return "‹"
        case .arrowRight: return "›"
        case .x: return "✕"
        case .checkmark, .checkmarkCircle: return "✓"
        case .speechBubble, .threeDotSpeechBubble: return "💬"
        case .speechBubbleOff: return "⊘"
        case .videoCamera: return "📷"
        case .paperAirplane: return "✈"
        case .twoArrowsClockwise: return "↻"
        case .speakerWithOneArc, .speakerWithTwoArcs, .speakerWithThreeArcs: return "🔊"
        case .smartGlasses: return "👓"
        case .exclamationTriangle, .exclamationCircle: return "⚠"
        case .circle8RaysLarge: return "✦"
        case .phone: return "📱"
        case .eye: return "👁"
        case .star: return "★"
        case .heart: return "♥"
        case .plus: return "+"
        default: return nil
        }
    }
}
