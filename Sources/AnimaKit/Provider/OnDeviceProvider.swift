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

    public init(instructions: String, history: [OnDeviceTranscriptEntry], prompt: String,
                tools: [OnDeviceToolDefinition], maxResponseTokens: Int) {
        self.instructions = instructions
        self.history = history
        self.prompt = prompt
        self.tools = tools
        self.maxResponseTokens = maxResponseTokens
    }
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
    case integer(description: String?)
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
        if case .prompt(let last)? = entries.last {
            prompt = last
            entries.removeLast()
        } else {
            prompt = continuationCue
        }

        // 4. Solo tools client-side: las server-side (web_search) necesitan red.
        let definitions: [OnDeviceToolDefinition] = tools.compactMap { spec in
            guard case .client(let name, let description, let schema) = spec else { return nil }
            return OnDeviceToolDefinition(name: name, description: description,
                                          schema: OnDeviceSchema.from(jsonSchema: schema, name: name))
        }

        return OnDeviceRequest(instructions: instructionParts.joined(separator: "\n\n"),
                               history: entries, prompt: prompt, tools: definitions,
                               maxResponseTokens: opts.route.maxTokens)
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
                func usage() -> Usage {
                    Usage(inputTokens: inputTokens, outputTokens: Int(Double(tracker.text.count) / 3.6))
                }

                do {
                    for try await element in session.stream(request) {
                        switch element {
                        case .snapshot(let snapshot):
                            let delta = tracker.delta(for: snapshot)
                            if !delta.isEmpty { continuation.yield(.textDelta(delta)) }
                        case .toolCall(let name, let json):
                            toolCall = (name, json)
                        }
                    }
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
        case .integer:
            return DynamicGenerationSchema(type: Int.self)
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
