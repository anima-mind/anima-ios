// Surface.swift — la tercera dimensión de extensibilidad (doc 05 §3.2, §6.3):
// la mente habla SEMÁNTICA y cada superficie la proyecta a su idioma. El
// teléfono (ChatViewModel → PhoneChatSurface) y las gafas (GlassesHUDSurface)
// cumplen el mismo contrato. La conversación es UNA (un transcript): el
// SurfaceRouter entrega cada turno a la superficie de origen + espejo en el
// teléfono, así abrir el teléfono es abrir otra ventana de la misma charla.

import Foundation

public enum SurfaceID: String, Sendable, Codable, Equatable, CaseIterable {
    case phoneChat
    case glassesHUD
}

public struct SurfaceCapabilities: Sendable, Equatable {
    public var freeText: Bool
    public var images: Bool
    public var maxButtons: Int
    public var voiceIn: Bool
    public var audioOut: Bool

    public init(freeText: Bool, images: Bool, maxButtons: Int, voiceIn: Bool, audioOut: Bool) {
        self.freeText = freeText
        self.images = images
        self.maxButtons = maxButtons
        self.voiceIn = voiceIn
        self.audioOut = audioOut
    }

    public static let phoneChat = SurfaceCapabilities(freeText: true, images: true, maxButtons: .max,
                                                      voiceIn: true, audioOut: false)
    /// Sin teclado en la cara: solo voz y botones (≤3 por vista).
    public static let glassesHUD = SurfaceCapabilities(freeText: false, images: true,
                                                       maxButtons: HUDValidator.maxButtons,
                                                       voiceIn: true, audioOut: true)
}

/// Contenido SEMÁNTICO (nunca visual) que la mente emite.
public enum SurfaceContent: Sendable, Equatable {
    /// El turno del dueño que llegó por otra superficie (espejo).
    case userTurn(text: String, origin: SurfaceID)
    /// La respuesta completa del asistente a un turno.
    case assistantTurn(text: String, origin: SurfaceID)
    case declined(text: String, origin: SurfaceID)
    /// "pensando…", errores amables.
    case status(String)
}

/// Lo que una superficie le entrega a la mente. La restricción de input de las
/// gafas está en el tipo: el HUD jamás emite `.userText` (no hay teclado).
public enum SurfaceEvent: Sendable, Equatable {
    case userText(String)
    case voiceTranscript(String)
    case buttonTapped(HUDActionID)
    case exited
}

@MainActor
public protocol Surface: AnyObject {
    var id: SurfaceID { get }
    var capabilities: SurfaceCapabilities { get }
    /// Proyección — pura, reemplazable, testeable.
    func render(_ content: SurfaceContent) async
    var events: AsyncStream<SurfaceEvent> { get }
}

/// El chat del teléfono: la superficie rica y privada. Además del contrato,
/// expone el ancla del último turno espejado (deep link "ver en el teléfono").
@MainActor
public protocol PhoneChatSurface: Surface {
    var lastMirroredTurnID: UUID? { get }
    func focus(turn: UUID?)
}

/// Único punto nuevo en el camino del turno (doc 05 §3.3): decide PROYECCIÓN,
/// no contenido. Origen + espejo en el teléfono.
@MainActor
public final class SurfaceRouter {
    private var surfaces: [SurfaceID: WeakSurface] = [:]

    public init() {}

    public func register(_ surface: any Surface) {
        surfaces[surface.id] = WeakSurface(surface)
    }

    public func surface(_ id: SurfaceID) -> (any Surface)? { surfaces[id]?.value }

    public var phone: (any PhoneChatSurface)? { surface(.phoneChat) as? any PhoneChatSurface }

    /// Entrega el contenido a la superficie de origen y lo espeja en el teléfono.
    public func route(_ content: SurfaceContent) async {
        let origin = Self.origin(of: content)
        var targets: [SurfaceID] = []
        if let origin { targets.append(origin) }
        if origin != .phoneChat { targets.append(.phoneChat) }
        for id in targets {
            await surface(id)?.render(content)
        }
    }

    static func origin(of content: SurfaceContent) -> SurfaceID? {
        switch content {
        case .userTurn(_, let origin), .assistantTurn(_, let origin), .declined(_, let origin): return origin
        case .status: return nil
        }
    }

    private final class WeakSurface {
        weak var value: (any Surface)?
        init(_ value: any Surface) { self.value = value }
    }
}

/// Deep links de la app (`anima://`). El mismo scheme recibe el callback de
/// Meta AI del registro DAT: lo que no es un deep link propio va a `handleUrl`.
public enum AnimaDeepLink: Sendable, Equatable {
    /// Abre el chat en el turno dado (handoff "ver en el teléfono").
    case chat(turn: UUID?)

    public static let scheme = "anima"

    public var url: URL {
        switch self {
        case .chat(let turn):
            var components = URLComponents()
            components.scheme = Self.scheme
            components.host = "chat"
            if let turn { components.queryItems = [URLQueryItem(name: "turn", value: turn.uuidString)] }
            return components.url!
        }
    }

    public static func parse(_ url: URL) -> AnimaDeepLink? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == "chat" else { return nil }
        let turn = components.queryItems?.first { $0.name == "turn" }?.value.flatMap(UUID.init(uuidString:))
        return .chat(turn: turn)
    }
}
