// HUDStateMachine.swift — la máquina de estados del HUD (handoff:
// Home → Listening → Heard → Thinking → Reply(speaking) → Answer(done)) como
// reductor PURO: (estado, evento) → (estado', efectos). La GlassesHUDSurface
// ejecuta los efectos (mic, turno, TTS, cámara, handoff) y re-envía la vista.
// Sin gestos crudos: todo evento de input es una acción de botón (doc 06 §4).

import Foundation

public enum HUDEvent: Sendable, Equatable {
    /// El usuario seleccionó un botón / FlexBox tappable (pinch o captouch).
    case action(HUDActionID)
    /// La ruta de audio asentó: glasses HFP (false) o degradó al teléfono (true).
    case listeningRoute(viaPhone: Bool)
    /// Fin de la captura de voz (nil/vacío = no se escuchó nada).
    case transcript(String?)
    /// El turno del AgentLoop terminó con esta respuesta (texto completo).
    case turnFinished(reply: String)
    case turnRefused(String)
    case turnFailed(String)
    /// El TTS terminó de decir la respuesta.
    case speechFinished
    /// `glasses_camera` pide confirmación pinch en las gafas.
    case cameraRequested(reason: String)
    /// `glasses_show`: el agente proyecta una card (ya validada).
    case agentCard(HUDFlexBox)
    /// Back físico / sesión terminada / gafas fuera: la sesión murió.
    case exited
}

public enum HUDEffect: Sendable, Equatable {
    case startListening
    case stopListening
    case submit(String)
    case cancelTurn
    case speak(String)
    case stopSpeaking
    case resolveCamera(Bool)
    case openPhone
}

public struct HUDConversationState: Sendable, Equatable {
    public var screen: HUDScreen
    /// Pantalla a la que se vuelve tras la confirmación de cámara.
    public var suspended: HUDScreen?
    /// Línea de estado corporal que muestra la Home (batería, etc.).
    public var status: String?

    public init(screen: HUDScreen = .home(status: nil), suspended: HUDScreen? = nil, status: String? = nil) {
        self.screen = screen
        self.suspended = suspended
        self.status = status
    }
}

public enum HUDStateMachine {

    public static func reduce(_ state: HUDConversationState, _ event: HUDEvent)
        -> (state: HUDConversationState, effects: [HUDEffect]) {
        var next = state
        let home = HUDScreen.home(status: state.status)

        // Transversales: cámara y salida de la sesión.
        switch event {
        case .cameraRequested(let reason):
            if case .cameraConfirm = state.screen { return (state, [.resolveCamera(false)]) }   // una a la vez
            var effects: [HUDEffect] = []
            if case .listening = state.screen { effects.append(.stopListening) }
            next.suspended = resumable(state.screen) ?? home
            next.screen = .cameraConfirm(reason: reason)
            return (next, effects)
        case .exited:
            var effects: [HUDEffect] = []
            switch state.screen {
            case .listening: effects.append(.stopListening)
            case .speaking: effects.append(.stopSpeaking)
            case .cameraConfirm: effects.append(.resolveCamera(false))
            default: break
            }
            return (HUDConversationState(screen: home, status: state.status), effects)
        default:
            break
        }

        switch (state.screen, event) {
        // Home
        case (.home, .action(.talk)):
            next.screen = .listening(viaPhone: false)
            return (next, [.startListening])

        // Listening
        case (.listening, .listeningRoute(let viaPhone)):
            next.screen = .listening(viaPhone: viaPhone)
            return (next, [])
        case (.listening, .action(.cancel)), (.listening, .action(.back)):
            next.screen = home
            return (next, [.stopListening])
        case (.listening, .transcript(let text)):
            let heard = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            next.screen = heard.isEmpty ? home : .heard(transcript: heard)
            return (next, [])

        // Heard (el transcript se muestra ANTES de enviarlo)
        case (.heard(let transcript), .action(.send)):
            next.screen = .thinking(question: transcript)
            return (next, [.submit(transcript)])
        case (.heard, .action(.again)):
            next.screen = .listening(viaPhone: false)
            return (next, [.startListening])
        case (.heard, .action(.back)):
            next.screen = home
            return (next, [])

        // Thinking
        case (.thinking, .action(.cancel)), (.thinking, .action(.back)):
            next.screen = home
            return (next, [.cancelTurn])
        case (.thinking, .turnFinished(let reply)), (.agentCard, .turnFinished(let reply)):
            let spoken = HUDSummary.spoken(from: reply)
            if case .agentCard = state.screen { return (next, spoken.isEmpty ? [] : [.speak(spoken)]) }
            let card = HUDSummary.card(from: reply)
            next.screen = spoken.isEmpty ? .answer(card) : .speaking(card)
            return (next, spoken.isEmpty ? [] : [.speak(spoken)])
        case (.thinking, .turnRefused(let text)):
            next.screen = .declined(text)
            return (next, [])
        case (.thinking, .turnFailed(let message)):
            next.screen = .attention(message)
            return (next, [])

        // Speaking → Answer (done)
        case (.speaking(let card), .speechFinished):
            next.screen = .answer(card)
            return (next, [])
        case (.speaking, .action(.reply)):
            next.screen = .listening(viaPhone: false)
            return (next, [.stopSpeaking, .startListening])
        case (.answer, .action(.reply)):
            next.screen = .listening(viaPhone: false)
            return (next, [.startListening])
        case (.speaking, .action(.onPhone)):
            next.screen = .handoff
            return (next, [.stopSpeaking, .openPhone])
        case (.answer, .action(.onPhone)), (.agentCard, .action(.onPhone)):
            next.screen = .handoff
            return (next, [.openPhone])
        case (.speaking, .action(.back)):
            next.screen = home
            return (next, [.stopSpeaking])

        // Cámara (pinch en las gafas)
        case (.cameraConfirm, .action(.cameraAllow)):
            next.screen = state.suspended ?? home
            next.suspended = nil
            return (next, [.resolveCamera(true)])
        case (.cameraConfirm, .action(.cameraDeny)), (.cameraConfirm, .action(.back)):
            next.screen = state.suspended ?? home
            next.suspended = nil
            return (next, [.resolveCamera(false)])

        // Card del agente: no interrumpe captura ni confirmación.
        case (.listening, .agentCard), (.heard, .agentCard), (.cameraConfirm, .agentCard):
            return (state, [])
        case (_, .agentCard(let box)):
            next.screen = .agentCard(box)
            return (next, [])
        case (.agentCard, .action(.talk)):
            next.screen = .listening(viaPhone: false)
            return (next, [.startListening])

        // Vistas terminales → Home
        case (.answer, .action(.back)), (.agentCard, .action(.back)), (.agentCard, .action(.dismiss)),
             (.declined, .action(.back)), (.attention, .action(.back)), (.handoff, .action(.back)):
            next.screen = home
            return (next, [])

        default:
            return (state, [])
        }
    }

    /// Pantallas a las que tiene sentido volver tras la cámara (el turno sigue).
    static func resumable(_ screen: HUDScreen) -> HUDScreen? {
        switch screen {
        case .listening, .cameraConfirm: return nil
        default: return screen
        }
    }
}
