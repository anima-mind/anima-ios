// OpenAICompatProvider.swift — córtex remoto para el wire format Chat Completions
// con SSE (POST {base_url}/chat/completions). Un solo provider sirve a OpenAI y a
// Google (Gemini vía su endpoint OpenAI-compatible): cambia la base_url y la key.
//
// Mapeo con el wire neutro (ContentBlock/Message):
//   system base                → messages[0] = {role:"system"}
//   Message role:.system       → {role:"system"} EN SU POSICIÓN (el wire lo acepta;
//                                 en Claude van al system top-level — PR #17)
//   toolUse (assistant)        → assistant.tool_calls[{id,type:function,function:{name,arguments}}]
//   toolResult (user)          → {role:"tool", tool_call_id, content}
//   image                      → content multiparte {type:image_url, image_url:{url:data:…}}
//   thinking                   → se omite (no hay equivalente)
//   ToolSpec.server            → se filtra (web_search es de Anthropic)

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Request builder (testeable sin red)

public enum OpenAICompatRequestBuilder {

    /// Reglas duras: stream + include_usage siempre; `max_completion_tokens`;
    /// NUNCA output_config/thinking (no existen aquí) y temperature no se manda
    /// por default (consistencia con el resto de córtex). Auth: Bearer.
    public static func build(context: AssembledContext, tools: [ToolSpec], opts: CallOpts) throws -> URLRequest {
        let data = try JSONEncoder().encode(JSONValue.object(body(context: context, tools: tools, opts: opts)))
        var req = URLRequest(url: opts.api.baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.httpBody = data
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")
        req.setValue("Bearer \(opts.token)", forHTTPHeaderField: "Authorization")
        return req
    }

    static func body(context: AssembledContext, tools: [ToolSpec], opts: CallOpts) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "model": .string(opts.route.model),
            "stream": .bool(true),
            "stream_options": .object(["include_usage": .bool(true)]),
            "max_completion_tokens": .int(opts.route.maxTokens),
            "messages": .array(encodeMessages(context.messages, systemBase: opts.systemPromptBase)),
        ]
        // Solo tools client-side, orden alfabético fijo. Array vacío → se omite
        // (el API rechaza `tools: []`).
        let client = tools.filter { if case .client = $0 { return true } else { return false } }
            .sorted { $0.name < $1.name }
        if !client.isEmpty {
            body["tools"] = .array(client.compactMap(encodeTool))
        }
        return body
    }

    static func encodeTool(_ spec: ToolSpec) -> JSONValue? {
        guard case .client(let name, let description, let schema) = spec else { return nil }
        return .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(name),
                "description": .string(description),
                "parameters": schema,
            ]),
        ])
    }

    static func encodeMessages(_ messages: [Message], systemBase: String) -> [JSONValue] {
        var out: [JSONValue] = [.object(["role": .string("system"), "content": .string(systemBase)])]
        for message in messages {
            out.append(contentsOf: encode(message))
        }
        return out
    }

    /// Un Message neutro puede abrirse en varios mensajes del wire: los
    /// tool_result de un turno user van como mensajes role:tool (deben seguir
    /// inmediatamente al assistant con tool_calls) y el resto como role:user.
    static func encode(_ message: Message) -> [JSONValue] {
        switch message.role {
        case .system:
            let text = texts(message.content).joined(separator: "\n\n")
            return text.isEmpty ? [] : [.object(["role": .string("system"), "content": .string(text)])]

        case .assistant:
            let text = texts(message.content).joined()
            let calls: [JSONValue] = message.content.compactMap { block in
                guard case .toolUse(let id, let name, let input) = block else { return nil }
                return .object([
                    "id": .string(id),
                    "type": .string("function"),
                    "function": .object(["name": .string(name), "arguments": .string(argumentsString(input))]),
                ])
            }
            guard !text.isEmpty || !calls.isEmpty else { return [] }  // p.ej. solo thinking
            var obj: [String: JSONValue] = [
                "role": .string("assistant"),
                "content": text.isEmpty ? .null : .string(text),
            ]
            if !calls.isEmpty { obj["tool_calls"] = .array(calls) }
            return [.object(obj)]

        case .user:
            var out: [JSONValue] = []
            for block in message.content {
                guard case .toolResult(let id, let content, let isError) = block else { continue }
                out.append(.object([
                    "role": .string("tool"),
                    "tool_call_id": .string(id),
                    "content": .string(isError ? "[error] " + content : content),
                ]))
            }
            let parts = message.content.compactMap(encodePart)
            if !parts.isEmpty {
                let hasImage = message.content.contains { if case .image = $0 { return true } else { return false } }
                let content: JSONValue = (!hasImage && parts.count == 1)
                    ? .string(texts(message.content).joined())
                    : .array(parts)
                out.append(.object(["role": .string("user"), "content": content]))
            }
            return out
        }
    }

    /// Parte de un content multiparte (text | image_url). Tool results/thinking/tool_use: nil.
    static func encodePart(_ block: ContentBlock) -> JSONValue? {
        switch block {
        case .text(let t):
            return .object(["type": .string("text"), "text": .string(t)])
        case .image(let mediaType, let base64):
            return .object([
                "type": .string("image_url"),
                "image_url": .object(["url": .string("data:\(mediaType);base64,\(base64)")]),
            ])
        default:
            return nil
        }
    }

    static func texts(_ blocks: [ContentBlock]) -> [String] {
        blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
    }

    /// `arguments` va como STRING JSON (así lo exige el wire). Claves ordenadas:
    /// el replay es byte-estable entre turnos.
    static func argumentsString(_ input: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(input), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - Parser SSE de Chat Completions → ProviderEvent

/// Traduce los chunks `data: {json}` a ProviderEvent. Con estado: los tool_calls
/// llegan fragmentados por `index` (id+nombre en el primer fragmento, los
/// argumentos troceados después) y el usage llega en el ÚLTIMO chunk (choices
/// vacío, include_usage) — por eso messageDelta/messageStop se emiten en
/// `[DONE]` (o al cerrar el stream), no en el finish_reason.
public struct OpenAICompatSSEParser: Sendable {
    private struct ToolState: Sendable {
        var id: String?
        var name: String?
        var pendingArgs = ""
        var started = false
    }

    private var started = false
    private var messageID = ""
    private var textOpen = false
    private var currentTool: Int?
    private var tools: [Int: ToolState] = [:]
    private var stopReason: StopReason?
    private var usage = Usage()
    private var finished = false
    private var blockIndex = 0

    public init() {}

    public mutating func handle(line: String) throws -> [ProviderEvent] {
        guard !finished, line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty else { return [] }
        if payload == "[DONE]" { return finish() }
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(RawCompatChunk.self, from: data) else {
            return []  // JSON no reconocido → ignorar, no romper el stream
        }
        if let error = chunk.error { throw Self.classify(error) }

        var events: [ProviderEvent] = []
        if !started {
            started = true
            messageID = chunk.id ?? ""
            events.append(.messageStart(id: messageID, model: chunk.model ?? ""))
        }
        if let u = chunk.usage {
            usage = Usage(inputTokens: u.promptTokens ?? 0, outputTokens: u.completionTokens ?? 0,
                          cacheReadInputTokens: u.promptTokensDetails?.cachedTokens)
        }
        guard let choice = chunk.choices?.first else { return events }

        if let delta = choice.delta {
            for text in [delta.content, delta.refusal].compactMap({ $0 }) where !text.isEmpty {
                events.append(contentsOf: closeTool())
                textOpen = true
                events.append(.textDelta(text))
            }
            if delta.refusal?.isEmpty == false { stopReason = .refusal }
            for call in delta.toolCalls ?? [] {
                events.append(contentsOf: handle(call))
            }
        }
        if let reason = choice.finishReason {
            events.append(contentsOf: closeText())
            events.append(contentsOf: closeTool())
            if stopReason != .refusal { stopReason = Self.stopReason(reason) }
        }
        return events
    }

    /// Cierre del mensaje: al recibir `[DONE]` o si el stream termina sin él.
    public mutating func finish() -> [ProviderEvent] {
        guard !finished else { return [] }
        finished = true
        guard started else { return [] }
        var events = closeText() + closeTool()
        events.append(.messageDelta(stopReason: stopReason, usage: usage))
        events.append(.messageStop)
        return events
    }

    private mutating func handle(_ call: RawCompatToolCall) -> [ProviderEvent] {
        let index = call.index ?? currentTool ?? 0
        var events: [ProviderEvent] = []
        if currentTool != index {
            events.append(contentsOf: closeText())
            events.append(contentsOf: closeTool())
            currentTool = index
        }
        var state = tools[index] ?? ToolState()
        if let id = call.id, !id.isEmpty { state.id = id }
        if state.name == nil, let name = call.function?.name, !name.isEmpty { state.name = name }
        state.pendingArgs += call.function?.arguments ?? ""
        // El bloque abre cuando ya hay nombre; los argumentos previos se retienen.
        if !state.started, let name = state.name {
            state.started = true
            let id = state.id ?? "call_\(messageID)_\(index)"
            state.id = id
            events.append(.toolUseStart(id: id, name: name))
        }
        if state.started, !state.pendingArgs.isEmpty {
            events.append(.toolUseInputDelta(state.pendingArgs))
            state.pendingArgs = ""
        }
        tools[index] = state
        return events
    }

    private mutating func closeText() -> [ProviderEvent] {
        guard textOpen else { return [] }
        textOpen = false
        defer { blockIndex += 1 }
        return [.blockStop(index: blockIndex)]
    }

    private mutating func closeTool() -> [ProviderEvent] {
        guard let index = currentTool else { return [] }
        currentTool = nil
        guard tools[index]?.started == true else { return [] }
        defer { blockIndex += 1 }
        return [.blockStop(index: blockIndex)]
    }

    static func stopReason(_ raw: String) -> StopReason {
        switch raw.lowercased() {
        case "tool_calls", "function_call": return .toolUse
        case "length", "max_tokens": return .maxTokens
        case "content_filter", "safety", "recitation": return .refusal
        default: return .endTurn
        }
    }

    static func classify(_ error: RawCompatError) -> ClassifiedError {
        let code = (error.code ?? error.type ?? "").lowercased()
        let message = error.message ?? "error SSE"
        if code.contains("context_length") || OpenAICompatErrors.isContextOverflow(message) {
            return .contextOverflow
        }
        if code.contains("rate_limit") || code.contains("resource_exhausted") || code == "429" {
            return .rateLimited(after: nil)
        }
        if code.contains("server_error") || code.contains("overloaded") || code.contains("unavailable")
            || (code.count == 3 && code.hasPrefix("5")) {
            return .retryable(after: nil)
        }
        return .fatal(status: -1, message: message)
    }

    // MARK: Helper sincrónico para tests

    public static func parse(lines: [String]) throws -> [ProviderEvent] {
        var parser = OpenAICompatSSEParser()
        var out: [ProviderEvent] = []
        for line in lines { out.append(contentsOf: try parser.handle(line: line)) }
        out.append(contentsOf: parser.finish())
        return out
    }
}

// MARK: - Clasificación de errores HTTP del wire compat

public enum OpenAICompatErrors {
    /// 400 de contexto: OpenAI (`context_length_exceeded`) y Gemini ("exceeds the
    /// maximum number of tokens"). Más estricto que el de Anthropic: aquí un 400
    /// por `max_completion_tokens` también dice "maximum" y NO es overflow.
    public static func classify(status: Int, retryAfter: String?, body: String) -> ClassifiedError {
        if status == 400 {
            return isContextOverflow(body) ? .contextOverflow : .fatal(status: 400, message: body)
        }
        return ErrorClassifier.classify(status: status, retryAfter: retryAfter, body: body)
    }

    static func isContextOverflow(_ body: String) -> Bool {
        let s = body.lowercased()
        return s.contains("context_length") || s.contains("context length")
            || s.contains("context window") || s.contains("maximum context")
            || (s.contains("token") && s.contains("exceeds the maximum"))
    }
}

// MARK: - Provider (streaming real con URLSession.bytes)

public struct OpenAICompatProvider: Provider {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try OpenAICompatRequestBuilder.build(context: ctx, tools: tools, opts: opts)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ClassifiedError.fatal(status: -1, message: "respuesta no-HTTP")
                    }
                    guard http.statusCode == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw OpenAICompatErrors.classify(
                            status: http.statusCode,
                            retryAfter: http.value(forHTTPHeaderField: "retry-after"),
                            body: body)
                    }
                    var parser = OpenAICompatSSEParser()
                    for try await line in bytes.lines {
                        for event in try parser.handle(line: line) { continuation.yield(event) }
                    }
                    for event in parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ErrorClassifier.classify(transport: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Formas crudas (tolerantes)

struct RawCompatChunk: Decodable {
    let id: String?
    let model: String?
    let choices: [RawCompatChoice]?
    let usage: RawCompatUsage?
    let error: RawCompatError?
}

struct RawCompatChoice: Decodable {
    let delta: RawCompatDelta?
    let finishReason: String?
    enum CodingKeys: String, CodingKey { case delta, finishReason = "finish_reason" }
}

struct RawCompatDelta: Decodable {
    let content: String?
    let refusal: String?
    let toolCalls: [RawCompatToolCall]?
    enum CodingKeys: String, CodingKey { case content, refusal, toolCalls = "tool_calls" }
}

struct RawCompatToolCall: Decodable {
    let index: Int?
    let id: String?
    let function: RawCompatFunction?
}

struct RawCompatFunction: Decodable {
    let name: String?
    let arguments: String?
}

struct RawCompatUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let promptTokensDetails: Details?
    struct Details: Decodable {
        let cachedTokens: Int?
        enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
    }
    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens", completionTokens = "completion_tokens"
        case promptTokensDetails = "prompt_tokens_details"
    }
}

struct RawCompatError: Decodable {
    let message: String?
    let type: String?
    let code: String?

    enum CodingKeys: String, CodingKey { case message, type, code }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        // `code` es string en OpenAI y entero (HTTP) en Gemini.
        if let s = try? c.decodeIfPresent(String.self, forKey: .code) {
            code = s
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .code) {
            code = String(i)
        } else {
            code = nil
        }
    }
}
