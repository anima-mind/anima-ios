// SSEParser.swift — traduce el stream SSE de /v1/messages a ProviderEvent (§4.3).
// Tolerante a eventos desconocidos (ping, tipos futuros): los ignora, no rompe.
// Parser con estado: acumula el usage de message_start (input/cache) y lo fusiona
// con el output de message_delta, para que messageDelta.usage sea completo.

import Foundation

public struct SSEParser: Sendable {
    private var startUsage: Usage?

    public init() {}

    /// Procesa una línea cruda del stream. Devuelve 0..n eventos.
    /// Lanza ClassifiedError si llega un evento `error`.
    public mutating func handle(line: String) throws -> [ProviderEvent] {
        guard line.hasPrefix("data:") else { return [] }  // ignora "event:" y keep-alives
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return [] }
        guard let data = payload.data(using: .utf8) else { return [] }

        let raw: RawSSEEvent
        do {
            raw = try JSONDecoder().decode(RawSSEEvent.self, from: data)
        } catch {
            return []  // JSON no reconocido → ignorar, no romper el stream
        }

        switch raw.type {
        case "message_start":
            if let msg = raw.message {
                startUsage = msg.usage
                return [.messageStart(id: msg.id ?? "", model: msg.model ?? "")]
            }
            return []

        case "content_block_start":
            if let block = raw.contentBlock,
               block.type == "tool_use" || block.type == "server_tool_use" {
                return [.toolUseStart(id: block.id ?? "", name: block.name ?? "")]
            }
            return []  // text | thinking → sin evento de inicio

        case "content_block_delta":
            guard let delta = raw.delta else { return [] }
            switch delta.type {
            case "text_delta":
                if let t = delta.text { return [.textDelta(t)] }
            case "thinking_delta":
                if let t = delta.thinking { return [.thinkingDelta(t)] }
            case "input_json_delta":
                if let p = delta.partialJSON { return [.toolUseInputDelta(p)] }
            default:
                return []  // signature_delta y otros: ignorar
            }
            return []

        case "content_block_stop":
            return [.blockStop(index: raw.index ?? 0)]

        case "message_delta":
            let merged = mergeUsage(delta: raw.usage)
            return [.messageDelta(stopReason: raw.delta?.stopReason, usage: merged)]

        case "message_stop":
            return [.messageStop]

        case "error":
            throw SSEParser.classify(error: raw.error)

        default:
            return []  // ping, tipos futuros
        }
    }

    /// Fusiona el input/cache usage de message_start con el output de message_delta.
    private func mergeUsage(delta: Usage?) -> Usage {
        var u = startUsage ?? Usage()
        if let d = delta {
            u.outputTokens = d.outputTokens
            if let r = d.cacheReadInputTokens { u.cacheReadInputTokens = r }
            if let c = d.cacheCreationInputTokens { u.cacheCreationInputTokens = c }
            if d.inputTokens > 0 { u.inputTokens = d.inputTokens }
        }
        return u
    }

    static func classify(error: RawSSEError?) -> ClassifiedError {
        switch error?.type {
        case "overloaded_error": return .retryable(after: 10)
        case "rate_limit_error": return .rateLimited(after: nil)
        case "api_error": return .retryable(after: nil)
        default: return .fatal(status: -1, message: error?.message ?? "error SSE")
        }
    }

    // MARK: - Helper sincrónico para tests / fixtures

    /// Parsea una secuencia completa de líneas SSE en eventos.
    public static func parse(lines: [String]) throws -> [ProviderEvent] {
        var parser = SSEParser()
        var out: [ProviderEvent] = []
        for line in lines {
            out.append(contentsOf: try parser.handle(line: line))
        }
        return out
    }

    /// Parsea un bloque SSE crudo (separado por \n).
    public static func parse(raw: String) throws -> [ProviderEvent] {
        try parse(lines: raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
    }
}

// MARK: - Formas crudas de decodificación (tolerantes)

struct RawSSEEvent: Decodable {
    let type: String
    let index: Int?
    let message: RawMessage?
    let contentBlock: RawContentBlock?
    let delta: RawDelta?
    let usage: Usage?
    let error: RawSSEError?

    enum CodingKeys: String, CodingKey {
        case type, index, message, delta, usage, error
        case contentBlock = "content_block"
    }
}

struct RawMessage: Decodable {
    let id: String?
    let model: String?
    let usage: Usage?
}

struct RawContentBlock: Decodable {
    let type: String?
    let id: String?
    let name: String?
}

struct RawDelta: Decodable {
    let type: String?
    let text: String?
    let thinking: String?
    let partialJSON: String?
    let stopReason: StopReason?

    enum CodingKeys: String, CodingKey {
        case type, text, thinking
        case partialJSON = "partial_json"
        case stopReason = "stop_reason"
    }
}

struct RawSSEError: Decodable {
    let type: String?
    let message: String?
}
