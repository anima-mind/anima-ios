// ClaudeProvider.swift — construcción del request, headers y streaming SSE
// contra POST {base_url}/v1/messages (§4.2, §4.3). URLSession directo, sin SDK.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Request builder (testeable sin red)

public enum ClaudeRequestBuilder {

    /// Construye el URLRequest de un turno. Reglas duras (§4.2):
    /// - stream: true siempre.
    /// - thinking: {"type":"adaptive","display":"summarized"} solo si el modelo lo permite.
    /// - output_config.effort solo si el modelo lo permite y la ruta lo trae.
    /// - NUNCA temperature/top_p/top_k/budget_tokens.
    /// - system = api.systemBlocks(for:mode,base:) como bloques text; cache_control
    ///   en el ÚLTIMO bloque del prefijo estable.
    /// - headers de auth según AuthMode; anthropic-beta = effectiveBetas(for:).
    public static func build(
        context: AssembledContext,
        tools: [ToolSpec],
        opts: CallOpts
    ) throws -> URLRequest {
        let policy = ModelParamPolicy.policy(for: opts.route.model)

        // --- Body como JSONValue (orden y tipos controlados) ---
        var body: [String: JSONValue] = [
            "model": .string(opts.route.model),
            "max_tokens": .int(opts.route.maxTokens),
            "stream": .bool(true),
        ]

        // thinking: adaptive con display summarized cuando hay razonamiento
        // (turnos con effort). Haiku (sin effort) va sin thinking.
        let thinkingEnabled = policy.allowsThinking && opts.route.effort != nil
        if thinkingEnabled {
            body["thinking"] = .object(["type": .string("adaptive"), "display": .string("summarized")])
        }
        if policy.allowsEffort, let effort = opts.route.effort {
            body["output_config"] = .object(["effort": .string(effort)])
        }

        // tools: orden fijo alfabético (jamás reordenar mid-session, §5.1).
        let sortedTools = tools.sorted { $0.name < $1.name }
        body["tools"] = .array(sortedTools.map(encodeTool))

        // system: bloques text; cache_control en el último (fin del prefijo estable).
        let blocks = opts.api.systemBlocks(for: opts.authMode, base: opts.systemPromptBase)
        body["system"] = .array(encodeSystemBlocks(blocks))

        // messages: se omiten los bloques thinking al reenviar (Fase 0).
        body["messages"] = .array(context.messages.map(encodeMessage))

        let data = try JSONEncoder().encode(JSONValue.object(body))

        // --- Request + headers ---
        let url = opts.api.baseURL.appendingPathComponent("v1/messages")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.timeoutInterval = 600  // el turno con thinking largo puede usar ~10 min (§4.3)
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let version = opts.api.version {
            req.setValue(version, forHTTPHeaderField: "anthropic-version")
        }
        switch opts.authMode {
        case .apiKey:
            req.setValue(opts.token, forHTTPHeaderField: "x-api-key")
        case .oauth:
            req.setValue("Bearer \(opts.token)", forHTTPHeaderField: "Authorization")
        }
        let betas = opts.api.effectiveBetas(for: opts.authMode)
        if !betas.isEmpty {
            req.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        return req
    }

    // MARK: Encoders

    static func encodeTool(_ spec: ToolSpec) -> JSONValue {
        switch spec {
        case .client(let name, let description, let schema):
            return .object([
                "name": .string(name),
                "description": .string(description),
                "input_schema": schema,
            ])
        case .server(let type, let name):
            return .object(["type": .string(type), "name": .string(name)])
        }
    }

    static func encodeSystemBlocks(_ blocks: [String]) -> [JSONValue] {
        blocks.enumerated().map { index, text in
            var obj: [String: JSONValue] = ["type": .string("text"), "text": .string(text)]
            if index == blocks.count - 1 {  // cache_control en el último bloque estable
                obj["cache_control"] = .object(["type": .string("ephemeral")])
            }
            return .object(obj)
        }
    }

    static func encodeMessage(_ message: Message) -> JSONValue {
        // Omite bloques thinking al reenviar (Fase 0: display summarized, sin replay de firmas).
        let blocks = message.content.filter {
            if case .thinking = $0 { return false }
            return true
        }
        let content: [JSONValue] = blocks.compactMap { block in
            guard let data = try? JSONEncoder().encode(block),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { return nil }
            return value
        }
        return .object(["role": .string(message.role.rawValue), "content": .array(content)])
    }
}

// MARK: - Provider (streaming real con URLSession.bytes)

public struct ClaudeProvider: Provider {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func complete(
        _ ctx: AssembledContext,
        tools: [ToolSpec],
        opts: CallOpts
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try ClaudeRequestBuilder.build(context: ctx, tools: tools, opts: opts)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ClassifiedError.fatal(status: -1, message: "respuesta no-HTTP")
                    }
                    guard http.statusCode == 200 else {
                        // Lee el cuerpo de error para clasificar (contextOverflow, etc.).
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw ErrorClassifier.classify(
                            status: http.statusCode,
                            retryAfter: http.value(forHTTPHeaderField: "retry-after"),
                            body: body)
                    }
                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        for event in try parser.handle(line: line) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ErrorClassifier.classify(transport: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
