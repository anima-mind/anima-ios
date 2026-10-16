// CarPlayTurn.swift — hablar con Anima en el carro (CarPlay, categoría "voice-based
// conversation", iOS 26.4+). Lo PURO de la superficie `.carplay`: textos que se
// dicen, la política de confirmaciones desde el carro, el buzón de confirmaciones
// de sus turnos, la sesión de audio y el modelo del template de voz. La
// conversación (CarPlayConversation) corre sobre el MISMO loop y sesión que el
// chat; el shell (App/CarPlay) solo proyecta este modelo a CPVoiceControlTemplate.
//
// Reglas de Apple que esto encarna (CarPlay Developer Guide, oct-2026):
//   · voz como modalidad primaria al abrir; nada de texto ni imágenes como
//     respuesta (la respuesta se DICE; en pantalla solo el estado);
//   · el template de voz a la vista mientras hay voz; ≤5 estados y ≤2 botones
//     de acción por estado;
//   · la sesión de audio se activa solo mientras se usa la voz
//     (.playAndRecord, modo default, sin mezclar) y se suelta al terminar.

import Foundation

public enum CarPlayTurn {
    /// CPVoiceControlState (iOS 26.4): hasta 2 botones de acción por estado.
    public static let maxButtons = 2
    /// Lo que se dice antes de remitir el resto al chat.
    public static let spokenLimit = HUDSummary.spokenLimit
    /// Jamás "toma el teléfono" (regla de CarPlay): el resto queda en el chat.
    public static let chatTail = "El resto te lo dejo en el chat."
    /// Fin del pedido por silencio: un poco más que las gafas (se habla manejando).
    public static let requestDetector = TurnEndDetector(silence: 1.5, maxDuration: 30)
    /// Un "sí" o un "no" es corto: corta antes y no escucha de más.
    public static let answerDetector = TurnEndDetector(silence: 1.0, maxDuration: 8)
    /// Cuánto se espera un "sí" o un "no" (voz o botón) antes de negar.
    public static let confirmTimeout: Duration = .seconds(20)

    public static let emptyText = "No te escuché. Toca Hablar cuando quieras."
    public static let interruptedText = "Se interrumpió la respuesta en CarPlay."
    public static let notReadyText = "Anima todavía no está lista en este teléfono. Termínala de configurar cuando no estés conduciendo."
    public static let offlineText = "Estoy sin conexión. Inténtalo cuando vuelva la red."
    public static let noAnswerHeard = "No te oí confirmar, así que no lo hice."
    public static let cameraRefusal = "Desde el carro no uso la cámara de las gafas."
    public static let pendingNotice = "Te dejé algo pendiente de CarPlay en el chat."

    /// Por qué no se pudo escuchar, dicho en el carro (sin mandar al iPhone).
    public static func voiceFailureText(_ failure: VoiceCaptureFailure) -> String {
        switch failure {
        case .speechPermissionDenied, .microphonePermissionDenied:
            "No tengo permiso para escucharte. Actívalo en Ajustes cuando no estés conduciendo."
        case .recognizerUnavailable:
            "El dictado en español no está disponible en este teléfono."
        case .microphoneUnavailable, .engineFailed:
            "No pude usar el micrófono del carro. Inténtalo de nuevo."
        }
    }

    /// La pregunta antes de una acción de bajo riesgo: corta, en voz.
    public static func confirmationPrompt(_ summary: String) -> String {
        "Para eso necesito tu ok: \(SiriTurn.plainSpeech(summary)). ¿Lo hago? Di sí o no."
    }

    /// Ya hay otro turno en vuelo (chat, gafas, Siri u otro de CarPlay).
    public static func busyText(_ holder: SurfaceID?) -> String {
        switch holder {
        case .carplay: "Sigo con lo anterior. Dame un momento."
        case .siri: "Estoy respondiendo algo que me pediste por Siri. Inténtalo en un momento."
        case .glassesHUD: "Estoy respondiendo en tus gafas. Inténtalo en un momento."
        default: "Estoy terminando otra respuesta. Inténtalo en un momento."
        }
    }

    // MARK: - Confirmaciones desde el carro

    /// Lo único que se confirma por voz o con Sí/No mientras se conduce: crear o
    /// completar cosas reversibles. Lo demás (borrar, la cámara, grabar…) se niega
    /// y queda pendiente en el teléfono (fail-closed: lo no listado es de riesgo).
    public static let voiceConfirmable: Set<AllowlistEntry> = Set(
        [AllowlistEntry(tool: "calendar", operation: "create"),
         AllowlistEntry(tool: "reminders", operation: "create"),
         AllowlistEntry(tool: "reminders", operation: "complete")]
        + PermissionPolicy.internalReversible)

    public static func isVoiceConfirmable(_ request: ConfirmationRequest) -> Bool {
        voiceConfirmable.contains(AllowlistEntry(tool: request.tool, operation: request.operation))
    }

    /// Por qué se niega SIN preguntar una acción pedida desde CarPlay (nil = se
    /// puede confirmar en el carro). Es el resultado de la tool: el modelo lo dice.
    public static func refusal(for request: ConfirmationRequest) -> String? {
        guard request.surface == .carplay else { return nil }
        if request.tool == GlassesCameraTool.name { return cameraRefusal }
        if isVoiceConfirmable(request) { return nil }
        return pendingRefusal(request.summary)
    }

    public static func pendingRefusal(_ summary: String) -> String {
        "No lo hice: mientras conduces no hago eso (\(summary)). Dile al dueño que se lo dejas pendiente en el teléfono."
    }

    /// ¿Lo negado queda como pendiente en el teléfono? (la cámara no: se niega y ya).
    public static func leavesPending(_ request: ConfirmationRequest) -> Bool {
        request.surface == .carplay && request.tool != GlassesCameraTool.name && !isVoiceConfirmable(request)
    }

    /// Lo que el dueño contestó en voz a "¿Lo hago?": true = sí, false = no,
    /// nil = no se entendió (se niega: fail-closed). Una negación gana a un sí
    /// ("sí, mejor no" ⇒ no).
    public static func parseAnswer(_ transcript: String) -> Bool? {
        let folded = transcript.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
        let words = folded.split { !$0.isLetter }.map(String.init)
        guard !words.isEmpty else { return nil }
        let joined = " " + words.joined(separator: " ") + " "
        let negative = ["no", "cancela", "cancelar", "cancelalo", "dejalo", "espera", "nunca", "tampoco", "negativo"]
        let positive = ["si", "dale", "hazlo", "claro", "ok", "okay", "listo", "adelante", "confirmo", "confirmado",
                        "va", "bueno", "porfa", "afirmativo", "correcto", "hagale", "perfecto"]
        let phrases = [" de una ", " por favor ", " me parece "]
        if words.contains(where: negative.contains) || joined.contains(" mejor no ") { return false }
        if words.contains(where: positive.contains) || phrases.contains(where: joined.contains) { return true }
        return nil
    }

    /// Una oración para el TTS: sin markdown ni emojis (el sintetizador los lee).
    public static func utterance(_ text: String) -> String {
        SiriTurn.plainSpeech(text)
    }
}

/// El buzón de confirmaciones de los turnos de CarPlay (SurfaceConfirmationRouter
/// le manda SOLO las de `.carplay`). Abierto mientras corre el turno: cada
/// pregunta se le pasa a quien la hace en el carro (`ask`); cerrado, se niega.
/// Además lleva la cuenta de lo que la política negó y quedó pendiente.
public final class CarPlayApprovals: ConfirmationProvider, @unchecked Sendable {
    public typealias Ask = @Sendable (ConfirmationRequest) async -> Bool

    private let lock = NSLock()
    private var listening = false
    private var asking = false
    private var ask: Ask?
    private var pending: [String] = []

    public init() {}

    /// Quien pregunta en el carro (la conversación de CarPlay).
    public func setAsk(_ ask: Ask?) { lock.withLock { self.ask = ask } }

    public func open() { lock.withLock { listening = true } }

    /// El turno terminó o se cortó: lo que venga se niega.
    public func close() { lock.withLock { listening = false } }

    public var isOpen: Bool { lock.withLock { listening } }

    /// Lo que quedó pendiente en el teléfono (y se vacía).
    public func takePending() -> [String] {
        lock.withLock {
            defer { pending = [] }
            return pending
        }
    }

    public func confirm(_ request: ConfirmationRequest) async -> Bool {
        guard !Task.isCancelled, request.surface == .carplay, CarPlayTurn.refusal(for: request) == nil else {
            return false
        }
        let ask = lock.withLock { () -> Ask? in
            guard listening, !asking, let ask = self.ask else { return nil }
            asking = true
            return ask
        }
        guard let ask else { return false }
        let approved = await ask(request)
        let stillOpen = lock.withLock { () -> Bool in
            asking = false
            return listening
        }
        return approved && stillOpen && !Task.isCancelled
    }

    public func refused(_ request: ConfirmationRequest) async {
        guard CarPlayTurn.leavesPending(request) else { return }
        lock.withLock { pending.append(request.summary) }
    }
}

// MARK: - Audio

/// La sesión de audio del carro: UNA por interacción de voz. Se activa al empezar
/// a escuchar (el dueño lo pidió) y se suelta al terminar de hablar, al
/// cancelar o ante un error — nunca queda abierta en reposo.
public protocol CarPlayAudioPort: Sendable {
    func activateConversation() throws
    func releaseConversation()
}

/// La configuración que pide Apple para esta categoría (WWDC26 "Rev up your
/// CarPlay app"): play-and-record, modo default, sin mezclar con otro audio.
/// Al soltarla se avisa a los demás (la música del carro vuelve).
public struct CarPlayAudioSpec: Sendable, Equatable {
    public enum Category: String, Sendable { case playAndRecord }
    public enum Mode: String, Sendable { case `default` }
    public var category: Category
    public var mode: Mode
    public var mixesWithOthers: Bool
    public var notifiesOthersOnRelease: Bool

    public static let conversation = CarPlayAudioSpec(category: .playAndRecord, mode: .default,
                                                      mixesWithOthers: false, notifiesOthersOnRelease: true)
}

/// Sin audio (tests, macOS).
public struct SilentCarPlayAudio: CarPlayAudioPort {
    public init() {}
    public func activateConversation() throws {}
    public func releaseConversation() {}
}

// MARK: - Template (proyección pura de la conversación)

/// En qué está la conversación del carro. Cada fase es UN estado del template
/// de voz (Apple: ≤5) con sus botones fijos (≤2).
public enum CarPlayPhase: Sendable, Equatable {
    case idle
    case listening
    case thinking
    case speaking
    /// Espera un "sí" o un "no" (la acción se dijo en voz, no se escribe).
    case confirming
}

public enum CarPlayButton: String, Sendable, Equatable, CaseIterable {
    case talk, done, cancel, stop, yes, no

    public var title: String {
        switch self {
        case .talk: "Hablar"
        case .done: "Listo"
        case .cancel: "Cancelar"
        case .stop: "Callar"
        case .yes: "Sí"
        case .no: "No"
        }
    }

    /// SF Symbol del botón (CPButton exige imagen).
    public var symbol: String {
        switch self {
        case .talk: "mic.fill"
        case .done: "checkmark"
        case .cancel: "xmark"
        case .stop: "speaker.slash.fill"
        case .yes: "hand.thumbsup.fill"
        case .no: "hand.thumbsdown.fill"
        }
    }
}

public struct CarPlayVoiceState: Sendable, Equatable {
    public var identifier: String
    /// El template elige la variante más larga que quepa.
    public var titleVariants: [String]
    public var symbol: String
    public var repeats: Bool
    public var buttons: [CarPlayButton]
}

public enum CarPlayTemplateModel {
    public static func identifier(_ phase: CarPlayPhase) -> String {
        switch phase {
        case .idle: "anima.idle"
        case .listening: "anima.listening"
        case .thinking: "anima.thinking"
        case .speaking: "anima.speaking"
        case .confirming: "anima.confirming"
        }
    }

    public static let phases: [CarPlayPhase] = [.idle, .listening, .thinking, .speaking, .confirming]

    /// Los estados del template, el de reposo PRIMERO (es el que se ve al abrir).
    public static func states(name: String) -> [CarPlayVoiceState] {
        phases.map { state($0, name: name) }
    }

    public static func state(_ phase: CarPlayPhase, name: String) -> CarPlayVoiceState {
        let name = displayName(name)
        switch phase {
        case .idle:
            return CarPlayVoiceState(identifier: identifier(phase), titleVariants: ["Hablar con \(name)", "Hablar"],
                                     symbol: "waveform.circle", repeats: false, buttons: [.talk])
        case .listening:
            return CarPlayVoiceState(identifier: identifier(phase), titleVariants: ["Te escucho…"],
                                     symbol: "waveform", repeats: true, buttons: [.done, .cancel])
        case .thinking:
            return CarPlayVoiceState(identifier: identifier(phase), titleVariants: ["Pensando…"],
                                     symbol: "ellipsis.circle", repeats: true, buttons: [.cancel])
        case .speaking:
            return CarPlayVoiceState(identifier: identifier(phase), titleVariants: ["\(name) responde…", "Respondiendo…"],
                                     symbol: "speaker.wave.2.circle", repeats: true, buttons: [.stop])
        case .confirming:
            return CarPlayVoiceState(identifier: identifier(phase), titleVariants: ["¿Lo hago?"],
                                     symbol: "questionmark.circle", repeats: false, buttons: [.yes, .no])
        }
    }

    /// El nombre en el título: corto (un nombre largo no cabe en el carro).
    public static func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Anima" }
        return HUDSummary.clip(trimmed, 18)
    }
}
