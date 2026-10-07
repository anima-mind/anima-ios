// AnimaDeepLink.swift — los deep links `anima://` (la app, las notificaciones y
// los widgets los arman y los parsean igual).

import Foundation

/// Deep links de la app (`anima://`). El mismo scheme recibe el callback de
/// Meta AI del registro DAT: lo que no es un deep link propio va a `handleUrl`.
public enum AnimaDeepLink: Sendable, Equatable {
    /// Abre el chat en el turno dado (handoff "ver en el teléfono").
    case chat(turn: UUID?)
    /// Re-entrada a las gafas tras un back físico (activa el cuerpo de nuevo).
    case glasses
    /// Un recordatorio de Anima entregado: chat con el foco en su mensaje.
    case reminder(id: String)
    /// El check-in de una meta: chat con la pregunta de seguimiento.
    case goal(id: String)
    /// Una Intention del pulso en background: chat con el foco en la propuesta.
    case intention(id: String)
    /// "Hablar con Anima" (Centro de control / botón de Acción / marca del
    /// widget con mic): chat con el micrófono ya escuchando (`anima://chat?mic=1`).
    case talk
    /// Widgets: tab Recordatorios.
    case reminders
    /// Widgets: tab Metas (con foco en una meta si viene el id).
    case goals(id: String?)
    /// El aviso de despertar (batch 8 #7): abre el Mind sheet.
    case mind

    public static let scheme = "anima"

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .chat(let turn):
            components.host = "chat"
            if let turn { components.queryItems = [URLQueryItem(name: "turn", value: turn.uuidString)] }
        case .glasses:
            components.host = "glasses"
        case .reminder(let id):
            components.host = "reminder"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        case .goal(let id):
            components.host = "goal"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        case .intention(let id):
            components.host = "intention"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        case .talk:
            components.host = "chat"
            components.queryItems = [URLQueryItem(name: "mic", value: "1")]
        case .reminders:
            components.host = "reminders"
        case .goals(let id):
            components.host = "goals"
            if let id { components.queryItems = [URLQueryItem(name: "id", value: id)] }
        case .mind:
            components.host = "mind"
        }
        return components.url!
    }

    public static func parse(_ url: URL) -> AnimaDeepLink? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let id = components.queryItems?.first { $0.name == "id" }?.value.flatMap { $0.isEmpty ? nil : $0 }
        switch components.host?.lowercased() {
        case "glasses":
            return .glasses
        case "chat":
            if components.queryItems?.contains(where: { $0.name == "mic" && $0.value == "1" }) == true {
                return .talk
            }
            let turn = components.queryItems?.first { $0.name == "turn" }?.value.flatMap(UUID.init(uuidString:))
            return .chat(turn: turn)
        case "reminder":
            return id.map { .reminder(id: $0) }
        case "goal":
            return id.map { .goal(id: $0) }
        case "intention":
            return id.map { .intention(id: $0) }
        case "reminders":
            return .reminders
        case "goals":
            return .goals(id: id)
        case "mind":
            return .mind
        default:
            return nil
        }
    }
}
