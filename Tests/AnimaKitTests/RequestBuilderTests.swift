import Foundation
import Testing
@testable import AnimaKit

@Suite struct RequestBuilderTests {

    private func decodedBody(_ request: URLRequest) throws -> JSONValue {
        let data = try #require(request.httpBody)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Regla dura: NUNCA temperature/top_p/top_k/budget_tokens en el body (→ 400).
    @Test func neverSendsForbiddenParams() throws {
        for mode in [AuthMode.apiKey, .oauth] {
            let opts = try TestConfig.callOpts(authMode: mode)
            let req = try ClaudeRequestBuilder.build(
                context: AssembledContext(messages: [.user("hola")]),
                tools: [NotesTool().spec, WebSearchTool.spec],
                opts: opts)
            let body = try decodedBody(req)
            let keys = body.allObjectKeys()
            #expect(!keys.contains("temperature"))
            #expect(!keys.contains("top_p"))
            #expect(!keys.contains("top_k"))
            #expect(!keys.contains("budget_tokens"))
        }
    }

    @Test func volatileSystemGoesToTopLevelBlocks() throws {
        // Verificado EN VIVO (400 real): la API rechaza role:system con texto dentro
        // de messages[]. El SelfView/banner van como bloque extra del system top-level
        // con su propio cache_control (el prefijo base conserva su hit).
        let opts = try TestConfig.callOpts(authMode: .apiKey)
        let req = try ClaudeRequestBuilder.build(
            context: AssembledContext(messages: [
                Message(role: .system, content: [.text("SELF: te llamas Anima")]),
                .user("hola"),
            ]),
            tools: [], opts: opts)
        let body = try decodedBody(req)
        // ningún role:system dentro de messages
        if case .array(let msgs) = body["messages"]! {
            #expect(msgs.count == 1)
            #expect(msgs.allSatisfy { $0.at("role") != .string("system") })
        } else { Issue.record("messages no es array") }
        // el system top-level termina con el bloque volátil, con su propio breakpoint
        if case .array(let sys) = body["system"]! {
            #expect(sys.count >= 2)
            #expect(sys.last?.at("text") == .string("SELF: te llamas Anima"))
            #expect(sys.last?.at("cache_control", "type") == .string("ephemeral"))
            // y el bloque anterior (fin del prefijo estable) TAMBIÉN conserva el suyo
            #expect(sys[sys.count - 2].at("cache_control", "type") == .string("ephemeral"))
        } else { Issue.record("system no es array") }
    }

    @Test func opusInteractiveBodyShape() throws {
        let opts = try TestConfig.callOpts(authMode: .apiKey)
        let req = try ClaudeRequestBuilder.build(
            context: AssembledContext(messages: [.user("hola")]),
            tools: [NotesTool().spec, WebSearchTool.spec],
            opts: opts)
        let body = try decodedBody(req)

        #expect(body["model"] == .string("claude-opus-4-8"))
        #expect(body["max_tokens"] == .int(16000))
        #expect(body["stream"] == .bool(true))
        // thinking adaptive, sin budget_tokens
        #expect(body.at("thinking", "type") == .string("adaptive"))
        #expect(body.at("thinking", "display") == .string("summarized"))
        // default de producción: thinking OFF hasta verificar replay con firma en device
        let defaultOpts = try TestConfig.callOpts(authMode: .apiKey, enableThinking: false)
        let defaultReq = try ClaudeRequestBuilder.build(
            context: AssembledContext(messages: [.user("hola")]),
            tools: [], opts: defaultOpts)
        let defaultBody = try decodedBody(defaultReq)
        #expect(defaultBody["thinking"] == nil)
        // effort en output_config, NUNCA top-level
        #expect(body.at("output_config", "effort") == .string("medium"))
        #expect(body["effort"] == nil)
        // tools ordenadas alfabéticamente: notes < web_search
        let tools = try #require(body["tools"]?.arrayValue)
        #expect(tools.count == 2)
        #expect(tools[0]["name"] == .string("notes"))
        #expect(tools[1]["type"] == .string("web_search_20260209"))
    }

    @Test func apiKeyModeHeadersAndSystem() throws {
        let opts = try TestConfig.callOpts(authMode: .apiKey, base: "PROMPT_BASE_ANIMA")
        let req = try ClaudeRequestBuilder.build(
            context: AssembledContext(messages: [.user("hola")]),
            tools: [], opts: opts)

        // Header x-api-key, sin Authorization
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-ant-api03-xyz")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        // anthropic-beta NO lleva las betas de oauth
        let beta = req.value(forHTTPHeaderField: "anthropic-beta") ?? ""
        #expect(!beta.contains("oauth-2025-04-20"))
        #expect(beta.contains("compact-2026-01-12"))
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

        // system: solo el base, sin prefijo Claude Code; cache_control en el último bloque
        let body = try decodedBody(req)
        let system = try #require(body["system"]?.arrayValue)
        #expect(system.count == 1)
        #expect(system[0]["text"] == .string("PROMPT_BASE_ANIMA"))
        #expect(system[0].at("cache_control", "type") == .string("ephemeral"))
    }

    @Test func oauthModeHeadersAndSystemPrefix() throws {
        let opts = try TestConfig.callOpts(authMode: .oauth, base: "PROMPT_BASE_ANIMA")
        let req = try ClaudeRequestBuilder.build(
            context: AssembledContext(messages: [.user("hola")]),
            tools: [], opts: opts)

        // Bearer, sin x-api-key
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat01-xyz")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == nil)
        // betas incluyen las de oauth
        let beta = req.value(forHTTPHeaderField: "anthropic-beta") ?? ""
        #expect(beta.contains("oauth-2025-04-20"))
        #expect(beta.contains("claude-code-20250219"))

        // system abre con el bloque Claude Code y luego el base; cache_control en el último
        let body = try decodedBody(req)
        let system = try #require(body["system"]?.arrayValue)
        #expect(system.count == 2)
        #expect(system[0]["text"] == .string("You are Claude Code, Anthropic's official CLI for Claude."))
        #expect(system[1]["text"] == .string("PROMPT_BASE_ANIMA"))
        #expect(system[0]["cache_control"] == nil)
        #expect(system[1].at("cache_control", "type") == .string("ephemeral"))
    }

    @Test func dropsThinkingBlocksFromResentMessages() throws {
        let opts = try TestConfig.callOpts(authMode: .apiKey)
        let assistant = Message.assistant([.thinking("interno"), .text("visible")])
        let req = try ClaudeRequestBuilder.build(
            context: AssembledContext(messages: [.user("hola"), assistant]),
            tools: [], opts: opts)
        let body = try decodedBody(req)
        let messages = try #require(body["messages"]?.arrayValue)
        let assistantContent = try #require(messages[1]["content"]?.arrayValue)
        // Solo el bloque text sobrevive; el thinking se omite al reenviar.
        #expect(assistantContent.count == 1)
        #expect(assistantContent[0]["type"] == .string("text"))
    }

    @Test func url() throws {
        let opts = try TestConfig.callOpts(authMode: .apiKey)
        let req = try ClaudeRequestBuilder.build(
            context: AssembledContext(messages: [.user("hola")]), tools: [], opts: opts)
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.httpMethod == "POST")
    }
}
