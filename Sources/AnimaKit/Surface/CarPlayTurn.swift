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
    /// Un "sí" o un "no" es corto: cada escucha corta antes y no oye de más; si
    /// no oyó nada se vuelve a escuchar hasta agotar `confirmTimeout`.
    public static let answerDetector = TurnEndDetector(silence: 1.0, maxDuration: 8)
    /// La ventana TOTAL para un "sí" o un "no" (voz o botón) antes de negar: las
    /// escuchas se repiten dentro de ella y los botones valen hasta el final.
    public static let confirmTimeout: Duration = .seconds(20)
    /// Pausa entre una escucha vacía y la siguiente (un mic que falla al
    /// instante no gira en vacío).
    public static let relistenPause: Duration = .milliseconds(250)

    public static let emptyText = "No te escuché. Toca Hablar cuando quieras."
    public static let interruptedText = "Se interrumpió la respuesta en CarPlay."
    public static let notReadyText = "Anima todavía no está lista en este teléfono. Termínala de configurar cuando no estés conduciendo."
    public static let offlineText = "Estoy sin conexión. Inténtalo cuando vuelva la red."
    public static let noAnswerHeard = "No te oí confirmar, así que no lo hice."
    /// Un "sí, pero…": la acción original NO se hace; la corrección es otra instrucción.
    public static let amendText = "Así como estaba no lo hice. Dime el cambio como una nueva instrucción."
    public static let unclearText = "No te entendí, así que no lo hice."
    public static let cameraRefusal = "Desde el carro no uso la cámara de las gafas."
    public static let pendingNotice = "Te dejé algo pendiente de CarPlay en el chat."
    /// La conversación en el carro existe desde iOS 26.4 (categoría y entitlement).
    public static let needsNewerIOSText = "Para hablar con Anima en el carro, actualiza el iPhone a iOS 26.4 o posterior."

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
        + PermissionPolicy.internalReversible.subtracting(PermissionPolicy.phoneOnly))

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

    /// Desde Siri (sin pantalla, quizá con el teléfono bloqueado) lo destructivo
    /// se niega siempre, aunque esté "Autorizado siempre".
    public static let siriDestructiveRefusal = "No lo hice: desde Siri no borro nada. Pídemelo en el chat."

    public static func pendingRefusal(_ summary: String) -> String {
        "No lo hice: mientras conduces no hago eso (\(summary)). Dile al dueño que se lo dejas pendiente en el teléfono."
    }

    /// ¿Lo negado queda como pendiente en el teléfono? (la cámara no: se niega y ya).
    public static func leavesPending(_ request: ConfirmationRequest) -> Bool {
        request.surface == .carplay && request.tool != GlassesCameraTool.name && !isVoiceConfirmable(request)
    }

    /// Lo que el dueño contestó en voz a "¿Lo hago?".
    public enum Answer: Sendable, Equatable {
        /// Un sí limpio: se hace la acción tal cual se dijo.
        case approve
        case deny
        /// Un sí con condición ("sí, pero a las cinco", "dale, cámbialo al
        /// viernes"): la acción original NO se hace; el cambio es otra instrucción.
        case amend
        /// No se entendió o dudó ("bueno, a ver", "va"): en la duda, no.
        case unclear

        public var approves: Bool { self == .approve }

        /// Lo que se dice antes de seguir (nil: el turno ya lo dirá).
        public var feedback: String? {
            switch self {
            case .approve, .deny: nil
            case .amend: CarPlayTurn.amendText
            case .unclear: CarPlayTurn.unclearText
            }
        }
    }

    static let negativeWords: Set<String> = ["no", "cancela", "cancelar", "cancelalo", "dejalo", "espera", "nunca",
                                             "tampoco", "negativo", "olvidalo", "detente", "alto"]
    /// Un sí que NO es ambiguo. "va", "bueno", "listo" o "porfa" solos no bastan.
    static let positiveWords: Set<String> = ["si", "dale", "hazlo", "hagale", "claro", "ok", "okay", "adelante",
                                             "confirmo", "confirmado", "afirmativo", "correcto", "perfecto",
                                             "exacto", "agendalo", "crealo"]
    /// Lo que cambia la acción: con cualquiera de estos, no se aprueba la original.
    static let amendWords: Set<String> = ["pero", "cambia", "cambialo", "cambiala", "cambiar", "mejor", "aunque",
                                          "excepto", "salvo", "mueve", "muevelo", "pasalo", "ponlo", "ponla",
                                          "manana", "pasado", "lunes", "martes", "miercoles", "jueves", "viernes",
                                          "sabado", "domingo", "tarde", "noche"]
    static let amendPhrases = [" a las ", " a la una ", " en vez ", " en lugar ", " solo si ", " siempre que ",
                               " con tal ", " otra hora ", " otro dia "]
    /// Duda: no hay un sí claro.
    static let doubtPhrases = [" a ver ", " creo ", " quizas ", " tal vez ", " puede ser ", " depende ", " mmm ",
                               " eh ", " este "]

    /// Negación gana; luego una condición (corrige ⇒ no); luego la duda; solo
    /// queda un sí si hay una palabra afirmativa inequívoca.
    public static func answer(_ transcript: String) -> Answer {
        let folded = transcript.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                        locale: Locale(identifier: "es"))
        let words = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return .unclear }
        let joined = " " + words.joined(separator: " ") + " "
        if words.contains(where: negativeWords.contains) { return .deny }
        if words.contains(where: amendWords.contains) || amendPhrases.contains(where: joined.contains)
            || words.contains(where: { $0.first?.isNumber == true }) {
            return .amend
        }
        if doubtPhrases.contains(where: joined.contains) { return .unclear }
        if words.contains(where: positiveWords.contains) || joined.contains(" de una ") { return .approve }
        return .unclear
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
