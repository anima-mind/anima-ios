import Foundation
import Testing
@testable import AnimaKit

extension JSONValue {
    /// Acceso por índice a un array (asserts sobre el body del request).
    subscript(_ index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }
}

// MARK: - Config compat para tests

enum CompatTestConfig {
    static let openAIBase = URL(string: "https://api.openai.com/v1")!
    static let googleBase = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!

    static func opts(token: String = "sk-test", base: URL = openAIBase,
                     model: String = "gpt-5.2", effort: String? = "medium",
                     maxTokens: Int = 4000, system: String = "Eres Anima.") -> CallOpts {
        CallOpts(route: ModelRoute(model: model, effort: effort, maxTokens: maxTokens),
                 api: ProviderAPIConfig(baseURL: base, version: nil, betas: []),
                 authMode: .apiKey, token: token, systemPromptBase: system,
                 relief: ReliefControls(clearStaleToolResults: true, compact: true),
                 enableThinking: true)
    }

    /// Body del request; dentro de URLProtocol llega como httpBodyStream.
    static func body(_ request: URLRequest) throws -> JSONValue {
        if let data = request.httpBody { return try JSONDecoder().decode(JSONValue.self, from: data) }
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - Request builder (sin red)

@Suite struct OpenAICompatRequestBuilderTests {

    private let notes = ToolSpec.client(name: "notes", description: "Notas",
                                        inputSchema: .object(["type": .string("object")]))
    private let calendar = ToolSpec.client(name: "calendar", description: "Agenda",
                                           inputSchema: .object(["type": .string("object")]))

    @Test func requestContractAndPolicy() throws {
        let opts = CompatTestConfig.opts()
        let req = try OpenAICompatRequestBuilder.build(
            context: AssembledContext(messages: [.user("hola")]), tools: [], opts: opts)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == nil)
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == nil)

        let body = try CompatTestConfig.body(req)
        #expect(body["model"] == .string("gpt-5.2"))
        #expect(body["stream"] == .bool(true))
        #expect(body.at("stream_options", "include_usage") == .bool(true))
        #expect(body["max_completion_tokens"] == .int(4000))
        // Aunque la ruta traiga effort, relief y thinking: nada de eso existe aquí.
        let keys = body.allObjectKeys()
        for forbidden in ["output_config", "thinking", "temperature", "max_tokens",
                          "context_management", "tools", "system", "cache_control"] {
            #expect(!keys.contains(forbidden), "\(forbidden)")
        }
        #expect(body["messages"]?[0] == .object(["role": .string("system"), "content": .string("Eres Anima.")]))
    }

    @Test func googleBaseKeepsItsPath() throws {
        let req = try OpenAICompatRequestBuilder.build(
            context: AssembledContext(messages: [.user("hola")]), tools: [],
            opts: CompatTestConfig.opts(base: CompatTestConfig.googleBase, model: "gemini-3-pro"))
        #expect(req.url?.absoluteString ==
                "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
    }

    @Test func clientToolsAsFunctionsSortedAndServerToolsFiltered() throws {
        let tools: [ToolSpec] = [notes, WebSearchTool.spec, calendar]
        let body = try CompatTestConfig.body(try OpenAICompatRequestBuilder.build(
            context: AssembledContext(messages: [.user("x")]), tools: tools, opts: CompatTestConfig.opts()))
        #expect(body["tools"] == .array([
            .object(["type": .string("function"), "function": .object([
                "name": .string("calendar"), "description": .string("Agenda"),
                "parameters": .object(["type": .string("object")])])]),
            .object(["type": .string("function"), "function": .object([
                "name": .string("notes"), "description": .string("Notas"),
                "parameters": .object(["type": .string("object")])])]),
        ]))
        // Solo server tools → sin clave tools.
        let onlyServer = try CompatTestConfig.body(try OpenAICompatRequestBuilder.build(
            context: AssembledContext(messages: [.user("x")]), tools: [WebSearchTool.spec],
            opts: CompatTestConfig.opts()))
        #expect(onlyServer["tools"] == nil)
        #expect(OpenAICompatRequestBuilder.encodeTool(WebSearchTool.spec) == nil)
    }

    @Test func volatileSystemMessagesStayInPlace() {
        let messages: [Message] = [
            .user("antes"),
            .assistant([.text("ok")]),
            Message(role: .system, content: [.text("SELF VIEW"), .text("segunda línea")]),
            Message(role: .system, content: [.text("[RESTRUCTURE] cambia")]),
            Message(role: .system, content: []),   // vacío: se omite
            .user("ahora"),
        ]
        let wire = OpenAICompatRequestBuilder.encodeMessages(messages, systemBase: "BASE")
        #expect(wire.map { $0["role"] } == [
            .string("system"), .string("user"), .string("assistant"),
            .string("system"), .string("system"), .string("user"),
        ])
        #expect(wire[0]["content"] == .string("BASE"))
        #expect(wire[3]["content"] == .string("SELF VIEW\n\nsegunda línea"))
        #expect(wire[4]["content"] == .string("[RESTRUCTURE] cambia"))
        #expect(wire[5]["content"] == .string("ahora"))
    }

    @Test func toolReplayAsAssistantToolCallsAndRoleTool() {
        let messages: [Message] = [
            .user("lee la nota"),
            .assistant([.thinking("pienso"), .text("Voy."),
                        .toolUse(id: "call_1", name: "notes",
                                 input: .object(["name": .string("clave"), "action": .string("read")]))]),
            .user([.toolResult(toolUseId: "call_1", content: "mango-42", isError: false),
                   .toolResult(toolUseId: "call_2", content: "no existe", isError: true)]),
            .assistant([.toolUse(id: "call_3", name: "notes", input: .object([:]))]),
            .assistant([.thinking("solo thinking")]),   // sin contenido replayable: se omite
        ]
        let wire = OpenAICompatRequestBuilder.encodeMessages(messages, systemBase: "B")
        #expect(wire.count == 6)
        #expect(wire[2] == .object([
            "role": .string("assistant"),
            "content": .string("Voy."),
            "tool_calls": .array([.object([
                "id": .string("call_1"), "type": .string("function"),
                "function": .object(["name": .string("notes"),
                                     "arguments": .string(#"{"action":"read","name":"clave"}"#)]),
            ])]),
        ]))
        #expect(wire[3] == .object(["role": .string("tool"), "tool_call_id": .string("call_1"),
                                    "content": .string("mango-42")]))
        #expect(wire[4] == .object(["role": .string("tool"), "tool_call_id": .string("call_2"),
                                    "content": .string("[error] no existe")]))
        #expect(wire[5]["content"] == .null)   // solo tool_calls → content null
        #expect(wire[5].at("tool_calls")?[0]?.at("function", "arguments") == .string("{}"))
    }

    @Test func geminiReplayCarriesThoughtSignatures() throws {
        let signed = Message.assistant([
            .toolUse(id: "call_1#ts=SIG1", name: "notes", input: .object([:])),
            .toolUse(id: "call_2", name: "calendar", input: .object([:])),
        ])
        let results = Message.user([.toolResult(toolUseId: "call_1#ts=SIG1", content: "ok", isError: false)])
        let wire = OpenAICompatRequestBuilder.encodeMessages([signed, results], systemBase: "B", model: "gemini-3.1-pro-preview")
        let calls = try #require(wire[1]["tool_calls"])
        #expect(calls[0]?["id"] == .string("call_1"))
        #expect(calls[0]?.at("extra_content", "google", "thought_signature") == .string("SIG1"))
        #expect(calls[1]?["extra_content"] == nil)          // paralela: solo la primera firma
        #expect(wire[2]["tool_call_id"] == .string("call_1"))

        // Historia sin firmas (otro modelo): Gemini recibe el comodín en la primera.
        let unsigned = Message.assistant([.toolUse(id: "call_x", name: "notes", input: .object([:])),
                                          .toolUse(id: "call_y", name: "notes", input: .object([:]))])
        let g = OpenAICompatRequestBuilder.encodeMessages([unsigned], systemBase: "B", model: "gemini-3.8-flash")
        #expect(g[1]["tool_calls"]?[0]?.at("extra_content", "google", "thought_signature")
                == .string(ThoughtSignature.skipValidator))
        #expect(g[1]["tool_calls"]?[1]?["extra_content"] == nil)
        // OpenAI jamás recibe extra_content.
        let o = OpenAICompatRequestBuilder.encodeMessages([unsigned], systemBase: "B", model: "gpt-5.2")
        #expect(!o[1].allObjectKeys().contains("extra_content"))
    }

    @Test func imagesGoAsMultipartDataURLs() {
        let wire = OpenAICompatRequestBuilder.encode(
            .user([.text("¿qué ves?"), .image(mediaType: "image/jpeg", base64: "AAAA")]))
        #expect(wire == [.object([
            "role": .string("user"),
            "content": .array([
                .object(["type": .string("text"), "text": .string("¿qué ves?")]),
                .object(["type": .string("image_url"),
                         "image_url": .object(["url": .string("data:image/jpeg;base64,AAAA")])]),
            ]),
        ])])
        // Varios textos sin imagen → también multiparte.
        let two = OpenAICompatRequestBuilder.encode(.user([.text("a"), .text("b")]))
        #expect(two.first?["content"] == .array([
            .object(["type": .string("text"), "text": .string("a")]),
            .object(["type": .string("text"), "text": .string("b")]),
        ]))
    }

    @Test func toolResultsPrecedeUserTextInSameTurn() {
        let wire = OpenAICompatRequestBuilder.encode(
            .user([.text("y además"), .toolResult(toolUseId: "c", content: "r", isError: false)]))
        #expect(wire.map { $0["role"] } == [.string("tool"), .string("user")])
    }

    @Test func policyForCompatFamily() {
        for model in ["gpt-5.2", "gpt-5-mini", "o3", "o4-mini", "gemini-3-pro", "gemini-3-flash", "chatgpt-4o"] {
            let p = ModelParamPolicy.policy(for: model)
            #expect(!p.allowsEffort, "\(model)")
            #expect(!p.allowsThinking, "\(model)")
            #expect(p.allowsTemperature, "\(model)")
        }
        #expect(!ModelParamPolicy.policy(for: "claude-opus-4-8").allowsTemperature)
        #expect(ModelParamPolicy.policy(for: "claude-opus-4-8").allowsEffort)
        #expect(!ModelParamPolicy.isOpenAICompatFamily("opus"))
        #expect(!ModelParamPolicy.isOpenAICompatFamily("system_language_model"))
    }
}

// MARK: - Parser SSE (sin red)

@Suite struct OpenAICompatSSEParserTests {

    @Test func textStreamWithUsageInLastChunk() throws {
        let events = try OpenAICompatSSEParser.parse(lines: [
            #"data: {"id":"chatcmpl-1","model":"gpt-5.2","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}"#,
            "",
            ": keep-alive",
            #"data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"Hola"}}]}"#,
            #"data: {"id":"chatcmpl-1","choices":[{"delta":{"content":" mundo"}}]}"#,
            #"data: {"id":"chatcmpl-1","choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            #"data: {"id":"chatcmpl-1","choices":[],"usage":{"prompt_tokens":30,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":10}}}"#,
            "data: [DONE]",
            #"data: {"choices":[{"delta":{"content":"tarde"}}]}"#,   // tras DONE: ignorado
        ])
        #expect(events == [
            .messageStart(id: "chatcmpl-1", model: "gpt-5.2"),
            .textDelta("Hola"), .textDelta(" mundo"),
            .blockStop(index: 0),
            .messageDelta(stopReason: .endTurn,
                          usage: Usage(inputTokens: 30, outputTokens: 5, cacheReadInputTokens: 10)),
            .messageStop,
        ])
    }

    @Test func fragmentedToolCallsBecomeToolUseBlocks() throws {
        let events = try OpenAICompatSSEParser.parse(lines: [
            #"data: {"id":"c2","model":"gpt-5.2","choices":[{"delta":{"content":"Miro."}}]}"#,
            #"data: {"id":"c2","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"notes","arguments":""}}]}}]}"#,
            #"data: {"id":"c2","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"action\":"}}]}}]}"#,
            #"data: {"id":"c2","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"list\"}"}}]}}]}"#,
            #"data: {"id":"c2","choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"calendar","arguments":"{}"}}]}}]}"#,
            #"data: {"id":"c2","choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            #"data: {"id":"c2","choices":[],"usage":{"prompt_tokens":50,"completion_tokens":20}}"#,
            "data: [DONE]",
        ])
        #expect(events == [
            .messageStart(id: "c2", model: "gpt-5.2"),
            .textDelta("Miro."),
            .blockStop(index: 0),
            .toolUseStart(id: "call_a", name: "notes"),
            .toolUseInputDelta(#"{"action":"#),
            .toolUseInputDelta(#""list"}"#),
            .blockStop(index: 1),
            .toolUseStart(id: "call_b", name: "calendar"),
            .toolUseInputDelta("{}"),
            .blockStop(index: 2),
            .messageDelta(stopReason: .toolUse, usage: Usage(inputTokens: 50, outputTokens: 20)),
            .messageStop,
        ])
    }

    @Test func toolCallWithoutIdAndNameArrivingLate() throws {
        // Args antes del nombre (se retienen) y sin id (se sintetiza estable).
        let events = try OpenAICompatSSEParser.parse(lines: [
            #"data: {"id":"g","model":"gemini-3-flash","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"a\":1}"}}]}}]}"#,
            #"data: {"id":"g","choices":[{"delta":{"tool_calls":[{"function":{"name":"notes"}}]}}]}"#,
            #"data: {"id":"g","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"notes"}}]}}]}"#,
            #"data: {"id":"g","choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        ])   // sin [DONE]: el finish() del cierre emite el final igual
        #expect(events == [
            .messageStart(id: "g", model: "gemini-3-flash"),
            .toolUseStart(id: "call_g_0", name: "notes"),
            .toolUseInputDelta(#"{"a":1}"#),
            .blockStop(index: 0),
            .messageDelta(stopReason: .toolUse, usage: Usage()),
            .messageStop,
        ])
    }

    @Test func textAfterToolClosesToolBlock() throws {
        let events = try OpenAICompatSSEParser.parse(lines: [
            #"data: {"id":"t","model":"m","choices":[{"delta":{"tool_calls":[{"index":0,"id":"x","function":{"name":"notes"}}]}}]}"#,
            #"data: {"id":"t","choices":[{"delta":{"content":"listo"}}]}"#,
            #"data: {"id":"t","choices":[{"delta":{},"finish_reason":"stop"}]}"#,
        ])
        #expect(events == [
            .messageStart(id: "t", model: "m"),
            .toolUseStart(id: "x", name: "notes"),
            .blockStop(index: 0),
            .textDelta("listo"),
            .blockStop(index: 1),
            // Hubo tool_call: aunque cierre con "stop", el turno es tool_use.
            .messageDelta(stopReason: .toolUse, usage: Usage()),
            .messageStop,
        ])
    }

    /// Forma real de Gemini 3 (verificada en vivo): tool_calls SIN index, con
    /// thought_signature en extra_content y finish_reason "stop".
    @Test func geminiToolCallsWithoutIndexAndStopFinish() throws {
        let events = try OpenAICompatSSEParser.parse(lines: [
            #"data: {"id":"g1","model":"gemini-3.1-pro-preview","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"extra_content":{"google":{"thought_signature":"SIG1"}},"function":{"arguments":"{\"action\":\"read\"}","name":"notes"},"id":"call_1","type":"function"},{"function":{"arguments":"{}","name":"calendar"},"id":"call_2","type":"function"}]}}]}"#,
            #"data: {"id":"g1","model":"gemini-3.1-pro-preview","choices":[{"delta":{"role":"assistant"},"finish_reason":"stop","index":0}],"usage":{"completion_tokens":20,"prompt_tokens":93}}"#,
            "data: [DONE]",
        ])
        #expect(events == [
            .messageStart(id: "g1", model: "gemini-3.1-pro-preview"),
            .toolUseStart(id: "call_1#ts=SIG1", name: "notes"),
            .toolUseInputDelta(#"{"action":"read"}"#),
            .blockStop(index: 0),
            .toolUseStart(id: "call_2", name: "calendar"),
            .toolUseInputDelta("{}"),
            .blockStop(index: 1),
            .messageDelta(stopReason: .toolUse, usage: Usage(inputTokens: 93, outputTokens: 20)),
            .messageStop,
        ])
    }

    @Test func thoughtSignatureEmbedAndSplit() {
        #expect(ThoughtSignature.embed(nil, in: "c") == "c")
        #expect(ThoughtSignature.embed("", in: "c") == "c")
        #expect(ThoughtSignature.embed("S/+=", in: "c") == "c#ts=S/+=")
        #expect(ThoughtSignature.split("c#ts=S/+=") == ("c", "S/+="))
        #expect(ThoughtSignature.split("c").signature == nil)
        #expect(ThoughtSignature.split("c#ts=").signature == nil)
    }

    @Test func finishReasonMapping() {
        #expect(OpenAICompatSSEParser.stopReason("stop") == .endTurn)
        #expect(OpenAICompatSSEParser.stopReason("STOP") == .endTurn)
        #expect(OpenAICompatSSEParser.stopReason("length") == .maxTokens)
        #expect(OpenAICompatSSEParser.stopReason("tool_calls") == .toolUse)
        #expect(OpenAICompatSSEParser.stopReason("function_call") == .toolUse)
        #expect(OpenAICompatSSEParser.stopReason("content_filter") == .refusal)
        #expect(OpenAICompatSSEParser.stopReason("desconocido") == .endTurn)
    }

    @Test func contentFilterIsRefusal() throws {
        let events = try OpenAICompatSSEParser.parse(lines: [
            #"data: {"id":"r","model":"gpt-5.2","choices":[{"delta":{},"finish_reason":"content_filter"}]}"#,
            "data: [DONE]",
        ])
        #expect(events.contains(.messageDelta(stopReason: .refusal, usage: Usage())))
    }

    @Test func refusalFieldStreamsAsTextAndStopsAsRefusal() throws {
        let events = try OpenAICompatSSEParser.parse(lines: [
            #"data: {"id":"r","model":"gpt-5.2","choices":[{"delta":{"refusal":"No puedo."}}]}"#,
            #"data: {"id":"r","choices":[{"delta":{},"finish_reason":"stop"}]}"#,
        ])
        #expect(events.contains(.textDelta("No puedo.")))
        #expect(events.contains(.messageDelta(stopReason: .refusal, usage: Usage())))
    }

    @Test func garbageAndEmptyStreamsDoNotBreak() throws {
        #expect(try OpenAICompatSSEParser.parse(lines: ["data: no-json", "event: x", "data:", "data: [DONE]"]) == [])
        var parser = OpenAICompatSSEParser()
        #expect(parser.finish() == [])
        #expect(parser.finish() == [])
    }

    @Test func streamedErrorsAreClassified() {
        func err(_ json: String) -> ClassifiedError? {
            do { _ = try OpenAICompatSSEParser.parse(lines: ["data: " + json]); return nil }
            catch { return error as? ClassifiedError }
        }
        #expect(err(#"{"error":{"message":"slow","type":"requests","code":"rate_limit_exceeded"}}"#) == .rateLimited(after: nil))
        #expect(err(#"{"error":{"message":"too long","code":"context_length_exceeded"}}"#) == .contextOverflow)
        #expect(err(#"{"error":{"message":"boom","type":"server_error"}}"#) == .retryable(after: nil))
        #expect(err(#"{"error":{"message":"quota","code":429,"status":"RESOURCE_EXHAUSTED"}}"#) == .rateLimited(after: nil))
        #expect(err(#"{"error":{"message":"caído","code":503}}"#) == .retryable(after: nil))
        #expect(err(#"{"error":{"message":"mala","code":"invalid_request_error"}}"#) == .fatal(status: -1, message: "mala"))
        #expect(err(#"{"error":{}}"#) == .fatal(status: -1, message: "error SSE"))
    }

    @Test func httpErrorClassification() {
        #expect(OpenAICompatErrors.classify(status: 400,
            retryAfter: nil, body: #"{"error":{"code":"context_length_exceeded"}}"#) == .contextOverflow)
        #expect(OpenAICompatErrors.classify(status: 400, retryAfter: nil,
            body: "The input token count (2000000) exceeds the maximum number of tokens allowed") == .contextOverflow)
        // "maximum" solo (p.ej. max_completion_tokens) NO es overflow aquí.
        let bad = "max_completion_tokens is too large: maximum is 128000"
        #expect(OpenAICompatErrors.classify(status: 400, retryAfter: nil, body: bad) == .fatal(status: 400, message: bad))
        #expect(OpenAICompatErrors.classify(status: 429, retryAfter: "4", body: "") == .rateLimited(after: 4))
        #expect(OpenAICompatErrors.classify(status: 503, retryAfter: nil, body: "") == .retryable(after: nil))
        #expect(OpenAICompatErrors.classify(status: 401, retryAfter: nil, body: "bad key") == .fatal(status: 401, message: "bad key"))
    }
}

// MARK: - Streaming real con URLProtocol stub

@Suite struct OpenAICompatProviderStreamingTests {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }()

    private static let sseHeaders = ["content-type": "text/event-stream"]
    private static let ctx = AssembledContext(messages: [.user("hola")])

    private func rig(_ responses: [[StubStep]]) -> (OpenAICompatProvider, CallOpts, StubScenario) {
        let token = "sk-proj-\(UUID().uuidString)"
        let scenario = StubScenario(responses)
        StubURLProtocol.registry.mutate { $0[token] = scenario }
        return (OpenAICompatProvider(session: Self.session), CompatTestConfig.opts(token: token), scenario)
    }

    private func collectError(_ provider: OpenAICompatProvider, _ opts: CallOpts) async -> Error? {
        do { _ = try await provider.completeCollecting(Self.ctx, tools: [], opts: opts); return nil }
        catch { return error }
    }

    private static let toolTurn = """
        data: {"id":"chatcmpl-9","model":"gpt-5.2","choices":[{"index":0,"delta":{"role":"assistant","content":"Leo "}}]}

        data: {"id":"chatcmpl-9","choices":[{"delta":{"content":"la nota."}}]}

        data: {"id":"chatcmpl-9","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"notes","arguments":""}}]}}]}

        data: {"id":"chatcmpl-9","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"action\\":\\"read\\","}}]}}]}

        data: {"id":"chatcmpl-9","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"name\\":\\"clave\\"}"}}]}}]}

        data: {"id":"chatcmpl-9","choices":[{"delta":{},"finish_reason":"tool_calls"}]}

        data: {"id":"chatcmpl-9","choices":[],"usage":{"prompt_tokens":120,"completion_tokens":18}}

        data: [DONE]


        """

    @Test func streamsToolTurnSplitMidLine() async throws {
        let raw = Self.toolTurn
        let cut = raw.index(raw.startIndex, offsetBy: raw.count / 2)
        let (provider, opts, scenario) = rig([[
            .http(status: 200, headers: Self.sseHeaders),
            .body(String(raw[..<cut])), .body(String(raw[cut...])), .finish,
        ]])
        let response = try await provider.completeCollecting(Self.ctx, tools: [WebSearchTool.spec], opts: opts)
        #expect(response.id == "chatcmpl-9")
        #expect(response.model == "gpt-5.2")
        #expect(response.content == [
            .text("Leo la nota."),
            .toolUse(id: "call_1", name: "notes",
                     input: .object(["action": .string("read"), "name": .string("clave")])),
        ])
        #expect(response.stopReason == .toolUse)
        #expect(response.usage == Usage(inputTokens: 120, outputTokens: 18))

        let request = try #require(scenario.requests.value.first)
        #expect(request.url?.path == "/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(opts.token)")
    }

    @Test func streamWithoutDoneStillFinishes() async throws {
        let body = """
            data: {"id":"x","model":"gemini-3-flash","choices":[{"delta":{"content":"hola"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1}}

            """
        let (provider, opts, _) = rig([[.http(status: 200, headers: Self.sseHeaders), .body(body), .finish]])
        let response = try await provider.completeCollecting(Self.ctx, tools: [], opts: opts)
        #expect(response.content == [.text("hola")])
        #expect(response.stopReason == .endTurn)
        #expect(response.usage == Usage(inputTokens: 3, outputTokens: 1))
    }

    @Test func rateLimitedHonorsRetryAfterThenRetrySucceeds() async throws {
        let (provider, opts, scenario) = rig([
            [.http(status: 429, headers: ["retry-after": "6"]), .body(#"{"error":{"code":"rate_limit_exceeded"}}"#), .finish],
            [.http(status: 200, headers: Self.sseHeaders), .body(Self.toolTurn), .finish],
        ])
        #expect(await collectError(provider, opts) as? ClassifiedError == .rateLimited(after: 6))
        let sleeps = Locked<[TimeInterval]>([])
        let (provider2, opts2, scenario2) = rig([
            [.http(status: 429, headers: ["retry-after": "6"]), .body("{}"), .finish],
            [.http(status: 200, headers: Self.sseHeaders), .body(Self.toolTurn), .finish],
        ])
        let response = try await withRetry(policy: RetryPolicy(maxAttempts: 3),
                                           sleep: { s in sleeps.mutate { $0.append(s) } }) { _ in
            try await provider2.completeCollecting(Self.ctx, tools: [], opts: opts2)
        }
        #expect(response.stopReason == .toolUse)
        #expect(scenario2.requests.value.count == 2)
        #expect(sleeps.value.first.map { $0 >= 6 } == true)
        #expect(scenario.requests.value.count == 1)
    }

    @Test func unauthorizedIsFatal() async throws {
        let (provider, opts, _) = rig([[.http(status: 401), .body("Incorrect API key provided"), .finish]])
        #expect(await collectError(provider, opts) as? ClassifiedError
                == .fatal(status: 401, message: "Incorrect API key provided"))
    }

    @Test func serverErrorIsRetryable() async throws {
        let (provider, opts, _) = rig([[.http(status: 502), .body("bad gateway"), .finish]])
        #expect(await collectError(provider, opts) as? ClassifiedError == .retryable(after: nil))
    }

    @Test func contextLengthIsOverflow() async throws {
        let (provider, opts, _) = rig([[
            .http(status: 400),
            .body(#"{"error":{"message":"This model's maximum context length is 400000 tokens.","code":"context_length_exceeded"}}"#),
            .finish,
        ]])
        #expect(await collectError(provider, opts) as? ClassifiedError == .contextOverflow)
    }

    @Test func contentFilterEndsAsRefusal() async throws {
        let body = """
            data: {"id":"f","model":"gpt-5.2","choices":[{"delta":{},"finish_reason":"content_filter"}]}

            data: [DONE]

            """
        let (provider, opts, _) = rig([[.http(status: 200, headers: Self.sseHeaders), .body(body), .finish]])
        let response = try await provider.completeCollecting(Self.ctx, tools: [], opts: opts)
        #expect(response.stopReason == .refusal)
        #expect(response.content.isEmpty)
    }

    @Test func streamedErrorMidStreamIsClassified() async throws {
        let body = """
            data: {"id":"e","model":"gpt-5.2","choices":[{"delta":{"content":"a"}}]}
            data: {"error":{"message":"overloaded","type":"server_error"}}

            """
        let (provider, opts, _) = rig([[.http(status: 200, headers: Self.sseHeaders), .body(body), .finish]])
        #expect(await collectError(provider, opts) as? ClassifiedError == .retryable(after: nil))
    }

    @Test func nonHTTPAndTransportErrors() async throws {
        let (p1, o1, _) = rig([[.nonHTTP, .body("x"), .finish]])
        #expect(await collectError(p1, o1) as? ClassifiedError == .fatal(status: -1, message: "respuesta no-HTTP"))
        let (p2, o2, _) = rig([[.fail(.timedOut)]])
        #expect(await collectError(p2, o2) as? ClassifiedError == .retryable(after: nil))
    }

    @Test func buildFailureSurfacesWithoutNetwork() async throws {
        let (provider, opts, scenario) = rig([])
        let tools: [ToolSpec] = [.client(name: "x", description: "d", inputSchema: .double(.nan))]
        var thrown: Error?
        do { for try await _ in provider.complete(Self.ctx, tools: tools, opts: opts) {} } catch { thrown = error }
        #expect(thrown != nil)
        #expect(scenario.requests.value.isEmpty)
    }

    /// Turno completo por el AgentLoop real: tool_call → NotesTool → role:tool → respuesta.
    @Test func agentLoopRunsCompatToolTurn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await NotesTool(root: root).execute(.object([
            "action": .string("create"), "name": .string("clave"), "content": .string("mango-42")]))

        let final = """
            data: {"id":"chatcmpl-10","model":"gpt-5.2","choices":[{"delta":{"content":"La palabra es mango-42."}}]}

            data: {"id":"chatcmpl-10","choices":[{"delta":{},"finish_reason":"stop"}]}

            data: [DONE]

            """
        let (provider, opts, scenario) = rig([
            [.http(status: 200, headers: Self.sseHeaders), .body(Self.toolTurn), .finish],
            [.http(status: 200, headers: Self.sseHeaders), .body(final), .finish],
        ])
        let config = ProviderConfig(systemPromptBase: "BASE", api: opts.api,
                                    routes: [.interactive: opts.route])
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let selector = ProviderSelector(
            mode: .remote,
            remote: .init(provider: provider, router: ModelRouter(config: config), authMode: .apiKey,
                          token: opts.token, kind: .openai),
            local: nil, availability: { .deviceNotEligible })
        let loop = AgentLoop(selector: selector, store: store, telemetry: Telemetry(queue: queue),
                             clientTools: [NotesTool(root: root)], serverTools: [WebSearchTool.spec],
                             sleep: { _ in })
        let sid = try store.startSession()
        var tools: [String] = []
        var text = ""
        var stop: StopReason?
        for await event in await loop.run(sessionId: sid, userText: "lee la nota clave") {
            switch event {
            case .toolFinished(let name, let isError): if !isError { tools.append(name) }
            case .textDelta(let t): text += t
            case .turnFinished(let s): stop = s
            default: break
            }
        }
        #expect(tools == ["notes"])
        #expect(text.contains("mango-42"))
        #expect(stop == .endTurn)

        let second = try CompatTestConfig.body(try #require(scenario.requests.value.last))
        let messages = try #require(second["messages"].flatMap { if case .array(let a) = $0 { a } else { nil } })
        #expect(messages.first?["content"] == .string("BASE"))
        #expect(messages.contains { $0["role"] == .string("system") && $0["content"] != .string("BASE") })  // SelfView
        let toolMsg = try #require(messages.first { $0["role"] == .string("tool") })
        #expect(toolMsg["tool_call_id"] == .string("call_1"))
        #expect(second["tools"]?[0]?.at("function", "name") == .string("notes"))   // web_search filtrada
        #expect(second["tools"]?[1] == nil)
    }
}
