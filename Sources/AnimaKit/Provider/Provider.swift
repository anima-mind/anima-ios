// Provider.swift — contratos de la capa de integración con Claude (plan doc 04 §4.1).
// URLSession directo, sin SDK (decisión fijada §2). Aquí viven los tipos del
// dominio del provider; ClaudeProvider los implementa contra /v1/messages.

import Foundation

// MARK: - Bloques de contenido (formato wire de la API)

/// Un bloque de contenido de un mensaje. Codable con la forma EXACTA que espera
/// la API (y que persiste el SymbolicStore). Los bloques `thinking` se guardan
/// full-fidelity pero el RequestBuilder los omite al reenviar (Fase 0: display
/// summarized sin replay de firmas — ver ClaudeRequestBuilder).
public enum ContentBlock: Sendable, Equatable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: String, isError: Bool)
    case image(mediaType: String, base64: String)
}

extension ContentBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, id, name, input
        case toolUseId = "tool_use_id", content, isError = "is_error", source
    }
    private enum SourceKeys: String, CodingKey {
        case type, mediaType = "media_type", data
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t, forKey: .text)
        case .thinking(let t):
            try c.encode("thinking", forKey: .type)
            try c.encode(t, forKey: .thinking)
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .toolResult(let toolUseId, let content, let isError):
            try c.encode("tool_result", forKey: .type)
            try c.encode(toolUseId, forKey: .toolUseId)
            try c.encode(content, forKey: .content)
            try c.encode(isError, forKey: .isError)
        case .image(let mediaType, let base64):
            try c.encode("image", forKey: .type)
            var s = c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            try s.encode("base64", forKey: .type)
            try s.encode(mediaType, forKey: .mediaType)
            try s.encode(base64, forKey: .data)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "thinking":
            self = .thinking(try c.decodeIfPresent(String.self, forKey: .thinking) ?? "")
        case "tool_use":
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                input: try c.decodeIfPresent(JSONValue.self, forKey: .input) ?? .object([:]))
        case "tool_result":
            self = .toolResult(
                toolUseId: try c.decode(String.self, forKey: .toolUseId),
                content: try c.decode(String.self, forKey: .content),
                isError: try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false)
        case "image":
            let s = try c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            self = .image(
                mediaType: try s.decode(String.self, forKey: .mediaType),
                base64: try s.decode(String.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "bloque desconocido: \(type)")
        }
    }
}

// MARK: - Mensajes

public struct Message: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable { case user, assistant, system }
    public var role: Role
    public var content: [ContentBlock]

    public init(role: Role, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> Message { .init(role: .user, content: [.text(text)]) }
    public static func user(_ blocks: [ContentBlock]) -> Message { .init(role: .user, content: blocks) }
    public static func assistant(_ blocks: [ContentBlock]) -> Message { .init(role: .assistant, content: blocks) }
}

// MARK: - Tools

/// Especificación de una tool en el array `tools[]`.
public enum ToolSpec: Sendable, Equatable {
    /// Tool client-side: el harness la ejecuta. `{name, description, input_schema}`.
    case client(name: String, description: String, inputSchema: JSONValue)
    /// Tool server-side de Anthropic: `{"type": "...", "name": "..."}`. Cero
    /// ejecución cliente (p.ej. web_search_20260209).
    case server(type: String, name: String)

    public var name: String {
        switch self {
        case .client(let n, _, _): return n
        case .server(_, let n): return n
        }
    }
}

public struct ToolResult: Sendable, Equatable {
    public var content: String
    public var isError: Bool
    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

public protocol HarnessTool: Sendable {
    var spec: ToolSpec { get }
    func execute(_ input: JSONValue) async -> ToolResult
}

// MARK: - Eventos del stream (§4.1)

public enum ProviderEvent: Sendable, Equatable {
    case messageStart(id: String, model: String)
    case textDelta(String)
    case thinkingDelta(String)               // resumen del razonamiento (display: summarized)
    case toolUseStart(id: String, name: String)
    case toolUseInputDelta(String)           // input_json_delta acumulable
    case blockStop(index: Int)
    case messageDelta(stopReason: StopReason?, usage: Usage)
    case messageStop
}

public enum StopReason: String, Sendable, Decodable, Equatable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case toolUse = "tool_use"
    case pauseTurn = "pause_turn"   // server tools: reenviar para continuar
    case refusal                    // chequear ANTES de leer content
    case stopSequence = "stop_sequence"
}

public struct Usage: Sendable, Decodable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadInputTokens: Int?
    public var cacheCreationInputTokens: Int?

    public init(inputTokens: Int = 0, outputTokens: Int = 0,
                cacheReadInputTokens: Int? = nil, cacheCreationInputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        self.outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        self.cacheReadInputTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens)
        self.cacheCreationInputTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens)
    }
}

// MARK: - Errores clasificados (§4.6)

public enum ClassifiedError: Error, Equatable {
    case retryable(after: TimeInterval?)     // 529, 5xx, desconexiones, timeouts
    case rateLimited(after: TimeInterval?)   // 429 (respeta retry-after)
    case contextOverflow                     // 400 de contexto → recuperable vía relieve
    case fatal(status: Int, message: String) // 400/401/403 — no reintentar
}

// MARK: - Contexto de llamada

/// Todo lo que el provider necesita para un turno, congelado por sesión.
public struct CallOpts: Sendable {
    public var route: ModelRoute
    public var api: ProviderAPIConfig
    public var authMode: AuthMode
    public var token: String
    public var systemPromptBase: String
    /// Gestión de contexto server-side del turno (§5.1). Default: sin alivio.
    public var relief: ReliefControls

    public init(route: ModelRoute, api: ProviderAPIConfig, authMode: AuthMode,
                token: String, systemPromptBase: String, relief: ReliefControls = .init()) {
        self.route = route
        self.api = api
        self.authMode = authMode
        self.token = token
        self.systemPromptBase = systemPromptBase
        self.relief = relief
    }
}

public struct AssembledContext: Sendable {
    public var messages: [Message]
    public init(messages: [Message]) { self.messages = messages }
}

/// Respuesta completa de un turno, ensamblada desde el stream de eventos.
public struct ProviderResponse: Sendable, Equatable {
    public var id: String
    public var model: String
    public var content: [ContentBlock]
    public var stopReason: StopReason?
    public var usage: Usage

    public init(id: String = "", model: String = "", content: [ContentBlock] = [],
                stopReason: StopReason? = nil, usage: Usage = .init()) {
        self.id = id
        self.model = model
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
    }

    public var toolCalls: [(id: String, name: String, input: JSONValue)] {
        content.compactMap {
            if case .toolUse(let id, let name, let input) = $0 { return (id, name, input) }
            return nil
        }
    }
}

// MARK: - Protocolo

public protocol Provider: Sendable {
    func complete(
        _ ctx: AssembledContext,
        tools: [ToolSpec],
        opts: CallOpts
    ) -> AsyncThrowingStream<ProviderEvent, Error>
}

extension Provider {
    /// Consume el stream y ensambla la respuesta completa. Acumula input_json_delta
    /// por bloque y lo parsea a JSON en el blockStop (§4.3). Reenvía cada evento a
    /// `onEvent` para el streaming en UI.
    public func completeCollecting(
        _ ctx: AssembledContext,
        tools: [ToolSpec],
        opts: CallOpts,
        onEvent: (@Sendable (ProviderEvent) -> Void)? = nil
    ) async throws -> ProviderResponse {
        var response = ProviderResponse(model: opts.route.model)
        var text = ""
        var thinking = ""
        // Estado del bloque tool_use en curso.
        var toolID: String?
        var toolName: String?
        var toolInputBuffer = ""

        func flushToolBlock() {
            guard let id = toolID, let name = toolName else { return }
            let input: JSONValue
            if toolInputBuffer.isEmpty {
                input = .object([:])
            } else if let data = toolInputBuffer.data(using: .utf8),
                      let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
                input = parsed
            } else {
                input = .object([:])
            }
            response.content.append(.toolUse(id: id, name: name, input: input))
            toolID = nil; toolName = nil; toolInputBuffer = ""
        }

        func flushText() {
            if !text.isEmpty { response.content.append(.text(text)); text = "" }
        }
        func flushThinking() {
            if !thinking.isEmpty { response.content.append(.thinking(thinking)); thinking = "" }
        }

        for try await event in complete(ctx, tools: tools, opts: opts) {
            onEvent?(event)
            switch event {
            case .messageStart(let id, let model):
                response.id = id
                response.model = model
            case .textDelta(let d):
                text += d
            case .thinkingDelta(let d):
                thinking += d
            case .toolUseStart(let id, let name):
                // Un nuevo bloque tool_use: cierra text/thinking pendientes.
                flushText(); flushThinking()
                toolID = id; toolName = name; toolInputBuffer = ""
            case .toolUseInputDelta(let d):
                toolInputBuffer += d
            case .blockStop:
                flushText(); flushThinking(); flushToolBlock()
            case .messageDelta(let stop, let usage):
                response.stopReason = stop
                response.usage = usage
            case .messageStop:
                flushText(); flushThinking(); flushToolBlock()
            }
        }
        // Por si el stream cierra sin blockStop/messageStop finales.
        flushText(); flushThinking(); flushToolBlock()
        return response
    }
}
