// OnDeviceProvider.swift — el córtex local (§4.9): implementa el MISMO protocol
// `Provider` sobre Apple Foundation Models. Sin red, sin auth, sin betas: ignora
// token/AuthMode/relief de CallOpts.
//
// Decisiones (§4.9, documentadas aquí porque el contrato de Claude no las cubre):
//
// 1. Provider sin estado: cada `complete` crea una sesión nueva con un
//    `Transcript` reconstruido desde `AssembledContext`. El transcript canónico
//    sigue siendo el SymbolicStore; la sesión del framework es desechable.
// 2. System prompt: no existe el mid-conversation system. Los mensajes
//    `role:system` del ensamblado (SelfView/SelfModel vivo, banner de
//    restructure) se CONCATENAN a las `Instructions` detrás de
//    `system_prompt_on_device`, recalculadas en cada llamada. Las instrucciones
//    tienen prioridad sobre el prompt en el modelo de Apple, que es justo la
//    autoridad que el canal de identidad necesita; las memorias activadas se
//    quedan en el prompt, como DATOS (defensa ante inyección, igual que en Claude).
// 3. Tools — puente NATIVO con intercepción: cada `SensorimotorTool` se expone
//    como `Tool` del framework con su JSON Schema traducido a
//    `DynamicGenerationSchema` (sin @Generable). El `call` del framework NO
//    ejecuta: lanza `OnDeviceToolInterception` con los argumentos, que se
//    convierte en un bloque `tool_use` normal. La ejecución sigue en el
//    AgentLoop → Sensorimotor.execute → PermissionPolicy (+ loop detection,
//    RealRegister, confirmación in-chat): los invariantes NO se delegan.
// 4. Streaming: el framework entrega snapshots ACUMULADOS; `SnapshotDeltaTracker`
//    los convierte en deltas para que ChatView streamee igual que con Claude.
// 5. Errores: contexto excedido → `.contextOverflow` (relieve mecánico local);
//    guardrails/refusal → `stopReason: .refusal` (refusal card, sin reintento);
//    modelo no disponible → `.fatal(status: unavailableStatus)` (el Híbrido cae a
//    Claude); todo lo demás → `.fatal` no-retryable.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Disponibilidad (siempre por runtime)

/// Por qué el modo local se puede (o no) usar en este teléfono. La UI la usa para
/// deshabilitar el modo con el porqué, jamás para esconderlo.
public enum OnDeviceAvailability: String, Sendable, Equatable, CaseIterable {
    case available
    case deviceNotEligible       // hardware sin Apple Intelligence
    case appleIntelligenceOff    // elegible, pero apagado en Ajustes del sistema
    case modelNotReady           // descargando / preparando assets
    case unknown                 // razón futura que el SDK aún no nombra

    public var isAvailable: Bool { self == .available }

    /// Etiqueta corta del estado (Ajustes / onboarding).
    public var label: String {
        switch self {
        case .available: return "Disponible en este teléfono"
        case .deviceNotEligible: return "Este teléfono no es compatible"
        case .appleIntelligenceOff: return "Apple Intelligence está apagado"
        case .modelNotReady: return "El modelo se está descargando"
        case .unknown: return "No disponible por ahora"
        }
    }

    /// El porqué, en una línea, cuando no se puede usar. `nil` si está disponible.
    public var reason: String? {
        switch self {
        case .available: return nil
        case .deviceNotEligible:
            return "Requiere un iPhone con Apple Intelligence (15 Pro o posterior)."
        case .appleIntelligenceOff:
            return "Actívalo en Ajustes › Apple Intelligence y Siri."
        case .modelNotReady:
            return "El modelo de Apple aún se está descargando; vuelve a intentarlo en unos minutos."
        case .unknown:
            return "El sistema no reporta el modelo local como listo."
        }
    }

    /// Lectura en vivo de `SystemLanguageModel.default.availability`.
    public static func current() -> OnDeviceAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .deviceNotEligible
                case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
                case .modelNotReady: return .modelNotReady
                @unknown default: return .unknown
                }
            }
        }
        #endif
        return .deviceNotEligible
    }
}

// MARK: - Sesión fina (mockeable) sobre LanguageModelSession

/// Una entrada del transcript reconstruido para la sesión local.
public enum OnDeviceTranscriptEntry: Sendable, Equatable {
    case prompt(String)
    case response(String)
    case toolCall(id: String, name: String, argumentsJSON: String)
    case toolOutput(id: String, name: String, content: String)
}

/// Una tool expuesta al modelo local (nombre + descripción + schema traducido).
public struct OnDeviceToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    public var schema: OnDeviceSchema

    public init(name: String, description: String, schema: OnDeviceSchema) {
        self.name = name
        self.description = description
        self.schema = schema
    }
}

/// Todo lo que la sesión local necesita para una respuesta.
public struct OnDeviceRequest: Sendable, Equatable {
    public var instructions: String
    public var history: [OnDeviceTranscriptEntry]
    public var prompt: String
    public var tools: [OnDeviceToolDefinition]
    public var maxResponseTokens: Int
    /// Continuación tras tools exitosas: la confirmación determinista si el
    /// modelo no logra redactar (guardrails, error). Con ella el texto no se
    /// streamea a medias: se entrega completo o se usa este fallback.
    public var fallbackText: String?
    /// Lo que la redacción debe nombrar para no perder el dato. Ver `acceptsConfirmation`.
    public var salientWords: [SalientGroup]

    public init(instructions: String, history: [OnDeviceTranscriptEntry], prompt: String,
                tools: [OnDeviceToolDefinition], maxResponseTokens: Int, fallbackText: String? = nil,
                salientWords: [SalientGroup] = []) {
        self.instructions = instructions
        self.history = history
        self.prompt = prompt
        self.tools = tools
        self.maxResponseTokens = maxResponseTokens
        self.fallbackText = fallbackText
        self.salientWords = salientWords
    }
}

/// Raíces que una confirmación debe nombrar: al menos `minimum` de `stems`.
public struct SalientGroup: Sendable, Equatable {
    public var stems: [String]
    public var minimum: Int

    public init(_ stems: [String], minimum: Int = 1) {
        self.stems = stems
        self.minimum = min(minimum, stems.count)
    }

    /// El sujeto de lo hecho: hasta 2 de sus raíces ("llamar al banco" ⇒ llam + banc).
    public static func subject(_ stems: [String]) -> SalientGroup { SalientGroup(stems, minimum: 2) }

    func isMet(by folded: String) -> Bool { stems.filter { folded.contains($0) }.count >= minimum }
}

/// Lo que emite la sesión: snapshots acumulados del texto (semántica del
/// framework) o la tool call interceptada (termina la respuesta).
public enum OnDeviceStreamElement: Sendable, Equatable {
    case snapshot(String)
    case toolCall(name: String, argumentsJSON: String)
}

/// Errores del framework, reducidos a lo que el harness distingue.
public enum OnDeviceSessionError: Error, Sendable, Equatable {
    case exceededContextWindow
    case guardrailViolation
    case refusal
    case assetsUnavailable
    case unsupportedLanguage
    case other(String)
}

/// Protocolo fino sobre `LanguageModelSession`: la única costura con el
/// framework. Los tests lo mockean (CI no tiene FoundationModels garantizado).
public protocol OnDeviceModelSession: Sendable {
    func stream(_ request: OnDeviceRequest) -> AsyncThrowingStream<OnDeviceStreamElement, Error>
}

/// Sesión para builds sin FoundationModels: siempre "sin assets".
public struct UnsupportedOnDeviceSession: OnDeviceModelSession {
    public init() {}
    public func stream(_ request: OnDeviceRequest) -> AsyncThrowingStream<OnDeviceStreamElement, Error> {
        AsyncThrowingStream { $0.finish(throwing: OnDeviceSessionError.assetsUnavailable) }
    }
}

// MARK: - Snapshots acumulados → deltas

/// El framework entrega el texto COMPLETO hasta el momento en cada snapshot; el
/// harness (y ChatView) trabajan con deltas. Si un snapshot no extiende al
/// anterior (reescritura), se emite lo nuevo tras el prefijo común: lo ya
/// mostrado no se retracta.
public struct SnapshotDeltaTracker: Sendable, Equatable {
    public private(set) var text: String = ""

    public init() {}

    public mutating func delta(for snapshot: String) -> String {
        defer { text = snapshot }
        if snapshot.hasPrefix(text) {
            return String(snapshot.dropFirst(text.count))
        }
        let common = snapshot.commonPrefix(with: text)
        return String(snapshot.dropFirst(common.count))
    }
}

// MARK: - JSON Schema → schema del modelo local

/// Representación pura (testeable sin el framework) del subconjunto de JSON
/// Schema que usan las tools del Sensorimotor. Se traduce 1:1 a
/// `DynamicGenerationSchema` en el build con FoundationModels.
public indirect enum OnDeviceSchema: Sendable, Equatable {
    case object(name: String, description: String?, properties: [Property])
    case string(description: String?, choices: [String]?)
    /// String con forma fija (`pattern` del JSON Schema): la generación guiada
    /// del framework solo produce texto que la cumple.
    case patterned(description: String?, pattern: String)
    case integer(description: String?)
    /// Entero acotado (`minimum`/`maximum`).
    case bounded(description: String?, range: ClosedRange<Int>)
    case number(description: String?)
    case boolean(description: String?)
    case array(description: String?, items: OnDeviceSchema)

    public struct Property: Sendable, Equatable {
        public var name: String
        public var description: String?
        public var schema: OnDeviceSchema
        public var isOptional: Bool
    }

    /// Traduce un JSON Schema. Propiedades en orden alfabético (estable); las no
    /// listadas en `required` son opcionales; tipos desconocidos degradan a string.
    public static func from(jsonSchema: JSONValue, name: String) -> OnDeviceSchema {
        let description = jsonSchema["description"]?.stringValue
        let type = jsonSchema["type"]?.stringValue
        let choices = jsonSchema["enum"]?.arrayValue?.compactMap(\.stringValue)
        switch type {
        case "object":
            let props = jsonSchema["properties"]?.objectValue ?? [:]
            let required = Set(jsonSchema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let properties = props.keys.sorted().map { key -> Property in
                let child = props[key] ?? .object([:])
                return Property(name: key,
                                description: child["description"]?.stringValue,
                                schema: from(jsonSchema: child, name: "\(name)_\(key)"),
                                isOptional: !required.contains(key))
            }
            return .object(name: name, description: description, properties: properties)
        case "integer":
            if case .int(let low)? = jsonSchema["minimum"], case .int(let high)? = jsonSchema["maximum"], low <= high {
                return .bounded(description: description, range: low...high)
            }
            return .integer(description: description)
        case "number":
            return .number(description: description)
        case "boolean":
            return .boolean(description: description)
        case "array":
            let items = jsonSchema["items"].map { from(jsonSchema: $0, name: "\(name)_item") }
                ?? .string(description: nil, choices: nil)
            return .array(description: description, items: items)
        default:
            if let pattern = jsonSchema["pattern"]?.stringValue, (choices?.isEmpty ?? true) {
                return .patterned(description: description, pattern: pattern)
            }
            return .string(description: description, choices: (choices?.isEmpty ?? true) ? nil : choices)
        }
    }
}

/// La tool call interceptada: el `call` del framework la lanza en vez de
/// ejecutar, y la sesión la convierte en `OnDeviceStreamElement.toolCall`.
public struct OnDeviceToolInterception: Error, Sendable, Equatable {
    public var name: String
    public var argumentsJSON: String
}

// MARK: - AssembledContext → request local (puro)

public enum OnDevicePromptBuilder {
    /// Cuando el contexto termina en resultados de tool, la sesión necesita un
    /// prompt para continuar: este cue le pide responder con ellos.
    public static let continuationCue =
        "Continúa: responde al dueño usando lo que devolvió la herramienta."
    /// Tras una ronda de tools sin errores el modelo local solo redacta: la
    /// continuación va SIN tools (con ellas el 3B repetía la llamada en bucle o
    /// el framework fallaba generando otra).
    /// Tras un fallo de tool: corregir una vez o admitirlo (nunca afirmar éxito).
    public static let errorCue =
        "La herramienta falló. Corrige los datos y llámala otra vez, o dile al dueño que no se pudo y por qué."

    /// Tras una lectura (list_reminders, read_note): responder con lo leído.
    public static func readPrompt(results: [String]) -> String {
        "Esto encontraste: " + results.joined(separator: " ")
            + "\nRespóndele (de tú) en 1-3 frases usando solo eso."
    }

    public static func successPrompt(results: [String]) -> String {
        "Ya lo hiciste: " + results.joined(separator: " ")
            + "\nConfírmaselo (de tú) en UNA frase que empiece con «Listo,» y diga solo lo que quedó hecho."
    }

    /// El turno del dueño como cita: sin esto el 3B respondía COMO el dueño
    /// ("pregúntame cómo voy" → "esta semana bajamos 1 kilo").
    public static func quotedOwner(_ text: String) -> String {
        "El dueño te dijo: «\(text)»"
    }
    /// Las imágenes no llegan al modelo local (no es multimodal en v1).
    public static let imagePlaceholder = "[imagen adjunta: el modelo local no puede verla]"

    public static func request(ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts) -> OnDeviceRequest {
        // 1. Instructions = prompt base del provider + los role:system del ensamblado.
        var instructionParts = [opts.systemPromptBase].filter { !$0.isEmpty }
        for message in ctx.messages where message.role == .system {
            let text = plainText(message.content)
            if !text.isEmpty { instructionParts.append(text) }
        }

        // 2. Transcript: user → prompt / toolOutput; assistant → response / toolCall.
        var entries: [OnDeviceTranscriptEntry] = []
        var toolNames: [String: String] = [:]
        func appendPrompt(_ text: String) {
            guard !text.isEmpty else { return }
            if case .prompt(let previous)? = entries.last {
                entries[entries.count - 1] = .prompt(previous + "\n\n" + text)
            } else {
                entries.append(.prompt(text))
            }
        }
        for message in ctx.messages where message.role != .system {
            switch message.role {
            case .user:
                var pending: [String] = []
                for block in message.content {
                    switch block {
                    case .text(let t): pending.append(t)
                    case .image: pending.append(imagePlaceholder)
                    case .toolResult(let id, let content, let isError):
                        appendPrompt(pending.joined(separator: "\n")); pending = []
                        entries.append(.toolOutput(id: id, name: toolNames[id] ?? "tool",
                                                   content: isError ? "ERROR: " + content : content))
                    case .thinking, .toolUse:
                        break
                    }
                }
                appendPrompt(pending.joined(separator: "\n"))
            case .assistant:
                var text: [String] = []
                for block in message.content {
                    switch block {
                    case .text(let t): text.append(t)
                    case .toolUse(let id, let name, let input):
                        if !text.isEmpty { entries.append(.response(text.joined())); text = [] }
                        toolNames[id] = name
                        entries.append(.toolCall(id: id, name: name, argumentsJSON: LoopDetector.canonical(input)))
                    case .thinking, .toolResult, .image:
                        break
                    }
                }
                if !text.isEmpty { entries.append(.response(text.joined())) }
            case .system:
                break
            }
        }

        // 3. El prompt del turno: el último bloque de prompt (memorias activadas +
        //    turn input ya vienen fusionados); si el contexto termina en tool
        //    output, el cue de continuación.
        let prompt: String
        var fallbackText: String?
        var salient: [SalientGroup] = []
        let toolsSucceeded = endsInSuccessfulToolResults(ctx.messages)
        if toolsSucceeded {
            // Éxito: la ronda de tools se pliega a texto ("Ya quedó hecho: …")
            // sobre el turno del dueño; sin estructura de tool el 3B redacta prosa.
            // Los pares fallidos de la ronda (redirect, reintento) no se cuentan:
            // "Listo: ERROR: …" llegaba al dueño.
            var round: [OnDeviceTranscriptEntry] = []
            while let last = entries.last {
                guard case .toolOutput = last else {
                    guard case .toolCall = last else { break }
                    round.insert(entries.removeLast(), at: 0)
                    continue
                }
                round.insert(entries.removeLast(), at: 0)
            }
            let failedIds = Set(round.compactMap { entry -> String? in
                if case .toolOutput(let id, _, let content) = entry, content.hasPrefix("ERROR: ") { return id }
                return nil
            })
            var results: [String] = []
            var onlyReads = true
            for entry in round {
                switch entry {
                case .toolOutput(let id, _, let content) where !failedIds.contains(id):
                    results.append(content)
                case .toolCall(let id, let name, let json) where !failedIds.contains(id):
                    if !LocalToolAdapter.readOnlyTools.contains(name) {
                        onlyReads = false
                        let args = normalizeArguments(json)
                        let subject = ["text", "statement", "title", "content"].compactMap { args[$0]?.stringValue }.first
                        if let subject, !salientStems(subject).isEmpty { salient.append(.subject(salientStems(subject))) }
                        if let action = Self.actionStems[name] { salient.append(SalientGroup(action)) }
                    }
                default:
                    break
                }
            }
            if onlyReads {
                results = results.map(withoutListIds)
                salient = listedItems(results.joined(separator: "\n")).prefix(3).map(salientStems)
                    .filter { !$0.isEmpty }.map { SalientGroup($0) }
            }
            let done = onlyReads ? readPrompt(results: results) : successPrompt(results: results)
            fallbackText = onlyReads ? results.joined(separator: "\n") : confirmation(results: results)
            if case .prompt(let owner)? = entries.last {
                entries.removeLast()
                prompt = quotedOwner(owner) + "\n" + done
            } else {
                prompt = done
            }
        } else if case .prompt(let last)? = entries.last {
            prompt = last
            entries.removeLast()
        } else {
            prompt = endsInToolError(ctx.messages) ? errorCue : continuationCue
        }

        // 4. Solo tools client-side: las server-side (web_search) necesitan red.
        let offered = toolsSucceeded ? [] : tools
        let definitions: [OnDeviceToolDefinition] = ToolProfile.onDevice.apply(offered).compactMap { spec in
            guard case .client(let name, let description, let schema) = spec else { return nil }
            return OnDeviceToolDefinition(name: name, description: description,
                                          schema: OnDeviceSchema.from(jsonSchema: schema, name: name))
        }

        return OnDeviceRequest(instructions: instructionParts.joined(separator: "\n\n"),
                               history: entries, prompt: prompt, tools: definitions,
                               maxResponseTokens: fallbackText == nil ? opts.route.maxTokens
                                   : min(opts.route.maxTokens, confirmationMaxTokens),
                               fallbackText: fallbackText, salientWords: salient)
    }

    /// "- [9F2C…] llamar al banco — …" → "- llamar al banco — …": el 3B leía los ids.
    static func withoutListIds(_ text: String) -> String {
        text.replacing(/\[[0-9A-Fa-f-]{8,}\]\s*/, with: "")
    }

    /// La confirmación tras tools es una frase: tope corto (y más rápido).
    public static let confirmationMaxTokens = 120

    /// ¿La redacción del modelo sirve como confirmación? Una o dos frases
    /// completas; si divaga (medido: "hoy me levanté a las 6…") o quedó cortada,
    /// va la confirmación determinista.
    /// Además: de tú (sin "el dueño" ni placeholders) y nombrando lo hecho o
    /// leído (medido: "El recordatorio está programado para mañana" sin decir cuál).
    /// Y debe decir la acción de Anima (recordar, anotar, agendar, registrar) sin
    /// afirmar que la tarea del dueño ya se hizo (medido: "Listo, sacué la basura",
    /// "Listo, revisé el horno", "me acordé de llamar al banco").
    public static func acceptsConfirmation(_ text: String, salient: [SalientGroup] = []) -> Bool {
        guard !text.isEmpty, text.count <= 240, let last = text.last, ".!?»)\"'".contains(last) else { return false }
        let folded = fold(text)
        if folded.contains("dueno") || text.contains("[") || claimsTheOwnersTask(text) || speaksAsTheOwner(folded) {
            return false
        }
        return salient.allSatisfy { $0.isMet(by: folded) }
    }

    /// Las cosas del dueño dichas como propias ("No tengo metas activas", "mis
    /// recordatorios"): medido en las lecturas vacías.
    static func speaksAsTheOwner(_ folded: String) -> Bool {
        let words = Set(folded.components(separatedBy: CharacterSet.letters.inverted))
        return words.contains("tengo") || words.contains("mis")
    }

    /// Lo que cada tool local hizo, como raíz: la confirmación debe nombrarlo.
    static let actionStems: [String: [String]] = [
        "remind_me": ["recuerd", "record", "avis", "program"],
        "declare_goal": ["meta", "regist", "pregunt", "segui", "recuerd"],
        "add_calendar_event": ["agend", "event", "calend", "cita", "reuni"],
        "write_note": ["anot", "nota", "guard", "apunt"],
    ]

    /// Pretérito en 1ª persona que no es de Anima ("saqué", "llamé") o en 2ª
    /// ("compraste"): afirma que la tarea del dueño ya ocurrió.
    /// También el perfecto que da por ocurrido el aviso ("ya te he recordado"),
    /// el reflexivo ("me he registrado") y el futuro de la tarea ("llevaré el carro").
    static func claimsTheOwnersTask(_ text: String) -> Bool {
        let all = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        for (index, word) in all.enumerated() {
            if word == "he", index + 1 < all.count {
                let next = all[index + 1]
                let participle = next.hasSuffix("ado") || next.hasSuffix("ido")
                if participle && (!ownParticiples.contains(next) || (index > 0 && all[index - 1] == "me")) { return true }
            }
            if ["hice", "fui", "puse", "traje"].contains(word) { return true }
            guard word.count > 3 else { continue }
            if word.hasSuffix("é") && !ownActions.contains(word) { return true }
            if word.hasSuffix("aste") || word.hasSuffix("iste") { return true }
        }
        return false
    }

    static let ownActions: Set<String> = ["anoté", "agendé", "registré", "guardé", "programé", "apunté", "dejé",
                                          "creé", "quedé", "recordaré", "avisaré", "preguntaré", "diré", "escribiré",
                                          "enviaré", "mandaré", "haré"]
    static let ownParticiples: Set<String> = ["anotado", "agendado", "registrado", "guardado", "programado",
                                              "apuntado", "creado", "dejado"]

    static func fold(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
    }

    static let stopwords: Set<String> = ["para", "como", "este", "esta", "esto", "todos", "todas", "cada", "antes",
                                         "despues", "sobre", "entre", "desde", "hasta", "porque", "cuando", "donde",
                                         "nota", "programados"]

    /// Raíces (4 letras) de las palabras con contenido: "llamar al banco" → ["llam", "banc"].
    static func salientStems(_ text: String) -> [String] {
        fold(text).components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 4 && !stopwords.contains($0) }
            .map { String($0.prefix(4)) }
    }

    /// Los ítems de una lista de la tool ("- llamar al banco — miércoles…" → "llamar al banco").
    static func listedItems(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("- ") else { return nil }
            let item = line.dropFirst(2)
            return String(item.components(separatedBy: " — ").first ?? String(item))
        }
    }

    /// "Listo: <resultado>" sin ids internos: lo que el dueño lee si el modelo
    /// no redacta la confirmación.
    public static func confirmation(results: [String]) -> String {
        let cleaned = results.map { result in
            result.replacing(/\s*\(id [^)]*\)/, with: "")
                .replacing(/\s*Id [A-Za-z0-9-]+\.?/, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let body = cleaned.joined(separator: " ")
        let trimmed = body.hasPrefix("Listo: ") ? String(body.dropFirst(7)) : body
        return "Listo: " + trimmed
    }

    /// ¿El contexto termina en resultados de tool con algún error?
    static func endsInToolError(_ messages: [Message]) -> Bool {
        guard let last = messages.last, last.role == .user else { return false }
        return last.content.contains { if case .toolResult(_, _, true) = $0 { return true } else { return false } }
    }

    /// ¿El contexto termina en resultados de tool, todos exitosos?
    static func endsInSuccessfulToolResults(_ messages: [Message]) -> Bool {
        guard let last = messages.last, last.role == .user else { return false }
        var sawResult = false
        for block in last.content {
            switch block {
            case .toolResult(_, _, let isError):
                if isError { return false }
                sawResult = true
            case .text, .thinking, .toolUse:
                return false
            case .image:
                continue
            }
        }
        return sawResult
    }

    /// Los números enteros llegan del framework como double (`7.0`): se
    /// normalizan a `.int` para que las tools lean `days_ahead` & co. igual que
    /// con Claude.
    public static func normalizeArguments(_ json: String) -> JSONValue {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .object([:])
        }
        return normalize(value)
    }

    static func normalize(_ value: JSONValue) -> JSONValue {
        switch value {
        case .double(let d) where d.rounded() == d && abs(d) < Double(Int.max):
            return .int(Int(d))
        case .array(let a): return .array(a.map(normalize))
        case .object(let o): return .object(o.mapValues(normalize))
        default: return value
        }
    }

    static func plainText(_ blocks: [ContentBlock]) -> String {
        blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
    }

    /// Estimación de tokens (sin tokenizer): chars/3.6, la misma heurística de
    /// WorkingMemory, para que la corrección por `usage` no se distorsione.
    static func estimateTokens(_ request: OnDeviceRequest) -> Int {
        var chars = request.instructions.count + request.prompt.count
        for entry in request.history {
            switch entry {
            case .prompt(let t), .response(let t): chars += t.count
            case .toolCall(_, let n, let a): chars += n.count + a.count
            case .toolOutput(_, _, let c): chars += c.count
            }
        }
        return Int(Double(chars) / 3.6)
    }
}

// MARK: - Provider

public struct OnDeviceProvider: Provider {
    /// El nombre de modelo de las rutas `on_device` en provider_config.
    public static let modelName = "system_language_model"
    /// La única pregunta "¿esta ruta es el modelo local?" del harness (perfil de
    /// tools, presupuesto de contexto, nombre visible, precio y selector).
    public static func isOnDevice(model: String) -> Bool { model == modelName }
    /// `.fatal(status:)` cuando el modelo local no está disponible (el Híbrido
    /// cae a Claude ante este código).
    public static let unavailableStatus = -10
    /// `.fatal(status:)` para cualquier otro fallo del framework.
    public static let failureStatus = -11

    private let session: any OnDeviceModelSession
    private let availability: @Sendable () -> OnDeviceAvailability

    public init(session: any OnDeviceModelSession,
                availability: @escaping @Sendable () -> OnDeviceAvailability) {
        self.session = session
        self.availability = availability
    }

    /// El provider real del sistema: FoundationModels si el SDK/OS lo tienen; si
    /// no, una sesión que reporta el modelo como no disponible.
    public static func system() -> OnDeviceProvider {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return OnDeviceProvider(session: SystemOnDeviceModelSession(),
                                    availability: { OnDeviceAvailability.current() })
        }
        #endif
        return OnDeviceProvider(session: UnsupportedOnDeviceSession(), availability: { .deviceNotEligible })
    }

    public func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        let session = self.session
        let availability = self.availability
        return AsyncThrowingStream { continuation in
            let task = Task {
                let status = availability()
                guard status.isAvailable else {
                    continuation.finish(throwing: ClassifiedError.fatal(
                        status: Self.unavailableStatus,
                        message: status.reason ?? status.label))
                    return
                }

                let request = OnDevicePromptBuilder.request(ctx: ctx, tools: tools, opts: opts)
                let inputTokens = OnDevicePromptBuilder.estimateTokens(request)
                continuation.yield(.messageStart(id: "ondevice_" + UUID().uuidString, model: Self.modelName))

                var tracker = SnapshotDeltaTracker()
                var toolCall: (name: String, json: String)?
                let buffered = request.fallbackText != nil
                func usage() -> Usage {
                    Usage(inputTokens: inputTokens, outputTokens: Int(Double(tracker.text.count) / 3.6))
                }

                do {
                    for try await element in session.stream(request) {
                        switch element {
                        case .snapshot(let snapshot):
                            let delta = tracker.delta(for: snapshot)
                            if !delta.isEmpty, !buffered { continuation.yield(.textDelta(delta)) }
                        case .toolCall(let name, let json):
                            toolCall = (name, json)
                        }
                    }
                } catch where buffered && !(error is CancellationError)
                            && (error as? OnDeviceSessionError) != .exceededContextWindow {
                    // Tras tools exitosas, un guardrail o fallo al redactar no
                    // deshace lo hecho: la confirmación determinista.
                    tracker = SnapshotDeltaTracker()
                } catch let error as OnDeviceSessionError {
                    switch error {
                    case .guardrailViolation, .refusal:
                        // Refusal-like: se muestra como refusal card, sin reintento.
                        if !tracker.text.isEmpty { continuation.yield(.blockStop(index: 0)) }
                        continuation.yield(.messageDelta(stopReason: .refusal, usage: usage()))
                        continuation.yield(.messageStop)
                        continuation.finish()
                    default:
                        continuation.finish(throwing: Self.classify(error))
                    }
                    return
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                    return
                } catch {
                    continuation.finish(throwing: ClassifiedError.fatal(
                        status: Self.failureStatus, message: error.localizedDescription))
                    return
                }

                if buffered {
                    let text = tracker.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    tracker = SnapshotDeltaTracker()
                    let accepted = OnDevicePromptBuilder.acceptsConfirmation(text, salient: request.salientWords)
                    _ = tracker.delta(for: accepted ? text : (request.fallbackText ?? ""))
                    toolCall = nil
                    continuation.yield(.textDelta(tracker.text))
                }
                var blockIndex = 0
                if !tracker.text.isEmpty {
                    continuation.yield(.blockStop(index: blockIndex))
                    blockIndex += 1
                }
                if let call = toolCall {
                    let id = "toolu_ondevice_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)
                    let input = OnDevicePromptBuilder.normalizeArguments(call.json)
                    continuation.yield(.toolUseStart(id: String(id), name: call.name))
                    continuation.yield(.toolUseInputDelta(LoopDetector.canonical(input)))
                    continuation.yield(.blockStop(index: blockIndex))
                    continuation.yield(.messageDelta(stopReason: .toolUse, usage: usage()))
                } else {
                    continuation.yield(.messageDelta(stopReason: .endTurn, usage: usage()))
                }
                continuation.yield(.messageStop)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Mapeo de errores del framework a la taxonomía del harness (§4.6).
    public static func classify(_ error: OnDeviceSessionError) -> ClassifiedError {
        switch error {
        case .exceededContextWindow:
            return .contextOverflow
        case .assetsUnavailable:
            return .fatal(status: unavailableStatus,
                          message: OnDeviceAvailability.modelNotReady.reason ?? "Modelo local no disponible.")
        case .unsupportedLanguage:
            return .fatal(status: failureStatus, message: "El modelo local no soporta este idioma.")
        case .guardrailViolation, .refusal:
            return .fatal(status: failureStatus, message: "El modelo local declinó responder.")
        case .other(let message):
            return .fatal(status: failureStatus, message: message)
        }
    }
}

// MARK: - Implementación con FoundationModels

#if canImport(FoundationModels)

/// Tool del framework que NO ejecuta: intercepta la llamada (ver decisión 3).
@available(iOS 26.0, macOS 26.0, *)
struct InterceptingTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema

    func call(arguments: GeneratedContent) async throws -> String {
        throw OnDeviceToolInterception(name: name, argumentsJSON: arguments.jsonString)
    }
}

@available(iOS 26.0, macOS 26.0, *)
enum OnDeviceSchemaBridge {
    static func generationSchema(for schema: OnDeviceSchema) throws -> GenerationSchema {
        try GenerationSchema(root: dynamic(schema, name: nameOf(schema) ?? "arguments"), dependencies: [])
    }

    private static func nameOf(_ schema: OnDeviceSchema) -> String? {
        if case .object(let name, _, _) = schema { return name }
        return nil
    }

    static func dynamic(_ schema: OnDeviceSchema, name: String) -> DynamicGenerationSchema {
        switch schema {
        case .object(let objectName, let description, let properties):
            return DynamicGenerationSchema(
                name: objectName, description: description,
                properties: properties.map { property in
                    DynamicGenerationSchema.Property(
                        name: property.name, description: property.description,
                        schema: dynamic(property.schema, name: "\(objectName)_\(property.name)"),
                        isOptional: property.isOptional)
                })
        case .string(let description, let choices):
            if let choices, !choices.isEmpty {
                return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
            }
            return DynamicGenerationSchema(type: String.self)
        case .patterned(_, let pattern):
            guard let regex = try? Regex(pattern) else { return DynamicGenerationSchema(type: String.self) }
            return DynamicGenerationSchema(type: String.self, guides: [.pattern(regex)])
        case .integer:
            return DynamicGenerationSchema(type: Int.self)
        case .bounded(_, let range):
            return DynamicGenerationSchema(type: Int.self, guides: [.range(range)])
        case .number:
            return DynamicGenerationSchema(type: Double.self)
        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)
        case .array(_, let items):
            return DynamicGenerationSchema(arrayOf: dynamic(items, name: "\(name)_item"))
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
public struct SystemOnDeviceModelSession: OnDeviceModelSession {
    public init() {}

    public func stream(_ request: OnDeviceRequest) -> AsyncThrowingStream<OnDeviceStreamElement, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Una tool cuyo schema no traduce se omite (el resto sigue): mejor
                    // un cuerpo parcial que ninguno.
                    let tools: [InterceptingTool] = request.tools.compactMap { definition in
                        guard let schema = try? OnDeviceSchemaBridge.generationSchema(for: definition.schema) else {
                            return nil
                        }
                        return InterceptingTool(name: definition.name, description: definition.description,
                                                parameters: schema)
                    }
                    let transcript = Self.transcript(for: request, tools: tools)
                    let session = LanguageModelSession(model: .default, tools: tools, transcript: transcript)
                    let options = GenerationOptions(maximumResponseTokens: request.maxResponseTokens)
                    for try await snapshot in session.streamResponse(to: request.prompt, options: options) {
                        continuation.yield(.snapshot(snapshot.content))
                    }
                    continuation.finish()
                } catch let error as LanguageModelSession.ToolCallError {
                    if let interception = error.underlyingError as? OnDeviceToolInterception {
                        continuation.yield(.toolCall(name: interception.name,
                                                     argumentsJSON: interception.argumentsJSON))
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: OnDeviceSessionError.other(error.localizedDescription))
                    }
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: Self.map(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func transcript(for request: OnDeviceRequest, tools: [InterceptingTool]) -> Transcript {
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: request.instructions))],
                toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }))
        ]
        var pendingCalls: [Transcript.ToolCall] = []
        func flushCalls() {
            guard !pendingCalls.isEmpty else { return }
            entries.append(.toolCalls(Transcript.ToolCalls(pendingCalls)))
            pendingCalls = []
        }
        for entry in request.history {
            switch entry {
            case .toolCall(let id, let name, let json):
                let arguments = (try? GeneratedContent(json: json)) ?? GeneratedContent(properties: [:])
                pendingCalls.append(Transcript.ToolCall(id: id, toolName: name, arguments: arguments))
            case .prompt(let text):
                flushCalls()
                entries.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: text))])))
            case .response(let text):
                flushCalls()
                entries.append(.response(Transcript.Response(
                    assetIDs: [], segments: [.text(Transcript.TextSegment(content: text))])))
            case .toolOutput(let id, let name, let content):
                flushCalls()
                entries.append(.toolOutput(Transcript.ToolOutput(
                    id: id, toolName: name, segments: [.text(Transcript.TextSegment(content: content))])))
            }
        }
        flushCalls()
        return Transcript(entries: entries)
    }

    static func map(_ error: LanguageModelSession.GenerationError) -> OnDeviceSessionError {
        switch error {
        case .exceededContextWindowSize: return .exceededContextWindow
        case .guardrailViolation: return .guardrailViolation
        case .refusal: return .refusal
        case .assetsUnavailable: return .assetsUnavailable
        case .unsupportedLanguageOrLocale: return .unsupportedLanguage
        default: return .other(error.localizedDescription)
        }
    }
}

#endif
