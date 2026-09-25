import Foundation
import Testing
@testable import AnimaKit

// MARK: - URLProtocol stub (red falsa por sesión, sin sockets)

/// Guion de una respuesta HTTP: pasos que el stub reproduce en orden.
enum StubStep: Sendable {
    case http(status: Int, headers: [String: String] = [:])
    case nonHTTP
    case body(String)
    case fail(URLError.Code)
    case finish
    /// Deja la conexión abierta (sin finish) — para cancelación.
    case hang
    /// Difiere el resto de los pasos (el cliente alcanza a consumir lo previo).
    case pause(TimeInterval)
}

/// Estado de un escenario. Se registra bajo el token del request (x-api-key),
/// así los tests corren en paralelo sin pisarse.
final class StubScenario: @unchecked Sendable {
    let responses: Locked<[[StubStep]]>
    let requests = Locked<[URLRequest]>([])
    let stopped = Locked(false)
    init(_ responses: [[StubStep]]) { self.responses = Locked(responses) }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = Locked<[String: StubScenario]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var scenario: StubScenario? {
        let key = request.value(forHTTPHeaderField: "x-api-key")
            ?? request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
            ?? ""
        return Self.registry.value[key]
    }

    override func startLoading() {
        guard let scenario else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        scenario.requests.mutate { $0.append(request) }
        let steps = scenario.responses.mutate { r -> [StubStep] in r.isEmpty ? [.fail(.badServerResponse)] : r.removeFirst() }
        play(steps[...])
    }

    private func play(_ steps: ArraySlice<StubStep>) {
        let url = request.url!
        for (offset, step) in zip(steps.indices, steps) {
            switch step {
            case .http(let status, let headers):
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                               headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            case .nonHTTP:
                let response = URLResponse(url: url, mimeType: "text/plain", expectedContentLength: -1,
                                           textEncodingName: nil)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            case .body(let s):
                client?.urlProtocol(self, didLoad: Data(s.utf8))
            case .fail(let code):
                client?.urlProtocol(self, didFailWithError: URLError(code))
                return
            case .finish:
                client?.urlProtocolDidFinishLoading(self)
                return
            case .hang:
                return
            case .pause(let seconds):
                let rest = steps[(offset + 1)...]
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { self.play(rest) }
                return
            }
        }
    }

    override func stopLoading() {
        scenario?.stopped.mutate { $0 = true }
    }
}

// MARK: - Tests del streaming real de ClaudeProvider

@Suite struct ClaudeProviderStreamingTests {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }()

    /// Registra el escenario bajo un token único y devuelve opts que lo usan.
    private func rig(_ responses: [[StubStep]], authMode: AuthMode = .apiKey)
        throws -> (ClaudeProvider, CallOpts, StubScenario) {
        let token = "sk-ant-api03-\(UUID().uuidString)"
        let scenario = StubScenario(responses)
        StubURLProtocol.registry.mutate { $0[token] = scenario }
        var opts = try TestConfig.callOpts(authMode: authMode)
        opts.token = token
        return (ClaudeProvider(session: Self.session), opts, scenario)
    }

    /// Con content-type explícito URLSession no retiene bytes para sniffing de MIME.
    private static let sseHeaders = ["content-type": "text/event-stream"]

    private static let ctx = AssembledContext(messages: [Message(role: .user, content: [.text("hola")])])

    private static let sseToolTurn = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":12}}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Voy "}}
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"a anotar."}}
        data: {"type":"content_block_stop","index":0}
        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"notes"}}
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"action\\":"}}
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"list\\"}"}}
        data: {"type":"content_block_stop","index":1}
        data: {"type":"ping"}
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}
        data: {"type":"message_stop"}

        """

    private func collectError(_ provider: ClaudeProvider, _ opts: CallOpts) async -> Error? {
        do {
            _ = try await provider.completeCollecting(Self.ctx, tools: [], opts: opts)
            return nil
        } catch {
            return error
        }
    }

    // MARK: SSE end-to-end

    @Test func streamsSSEBytesIntoAssembledResponse() async throws {
        // El body llega partido en dos chunks a mitad de línea: el provider
        // debe re-armar líneas antes de parsear.
        let raw = Self.sseToolTurn
        let cut = raw.index(raw.startIndex, offsetBy: raw.count / 2)
        let (provider, opts, scenario) = try rig([[
            .http(status: 200, headers: ["content-type": "text/event-stream"]),
            .body(String(raw[..<cut])), .body(String(raw[cut...])), .finish,
        ]])

        let seen = Locked<[ProviderEvent]>([])
        let response = try await provider.completeCollecting(Self.ctx, tools: [], opts: opts) { event in
            seen.mutate { $0.append(event) }
        }

        #expect(response.id == "msg_1")
        #expect(response.content == [
            .text("Voy a anotar."),
            .toolUse(id: "toolu_1", name: "notes", input: .object(["action": .string("list")])),
        ])
        #expect(response.stopReason == .toolUse)
        #expect(response.usage.inputTokens == 12)
        #expect(response.usage.outputTokens == 9)
        #expect(seen.value.first == .messageStart(id: "msg_1", model: "claude-opus-4-8"))
        #expect(seen.value.last == .messageStop)

        // El request salió con el contrato del builder (POST, auth, stream).
        let request = try #require(scenario.requests.value.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == opts.token)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    // MARK: Status no-200 → ClassifiedError

    @Test func rateLimitedWithRetryAfterHeader() async throws {
        let (provider, opts, _) = try rig([[
            .http(status: 429, headers: ["retry-after": "7"]),
            .body(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#), .finish,
        ]])
        let error = await collectError(provider, opts)
        #expect(error as? ClassifiedError == .rateLimited(after: 7))
    }

    @Test func overloaded529IsRetryableWithFloor() async throws {
        let (provider, opts, _) = try rig([[
            .http(status: 529), .body(#"{"type":"error","error":{"type":"overloaded_error"}}"#), .finish,
        ]])
        let error = await collectError(provider, opts)
        #expect(error as? ClassifiedError == .retryable(after: 10))
    }

    @Test func contextOverflow400ReadsErrorBody() async throws {
        let (provider, opts, _) = try rig([[
            .http(status: 400),
            .body(#"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 250000 tokens"}}"#),
            .finish,
        ]])
        let error = await collectError(provider, opts)
        #expect(error as? ClassifiedError == .contextOverflow)
    }

    @Test func unauthorizedIsFatalWithBody() async throws {
        let (provider, opts, _) = try rig([[.http(status: 401), .body("invalid x-api-key"), .finish]])
        let error = await collectError(provider, opts)
        #expect(error as? ClassifiedError == .fatal(status: 401, message: "invalid x-api-key"))
    }

    @Test func nonHTTPResponseIsFatal() async throws {
        let (provider, opts, _) = try rig([[.nonHTTP, .body("x"), .finish]])
        let error = await collectError(provider, opts)
        #expect(error as? ClassifiedError == .fatal(status: -1, message: "respuesta no-HTTP"))
    }

    // MARK: Retry end-to-end (429 → 200) con el withRetry real

    @Test func retriesAfter429ThenSucceeds() async throws {
        let ok = [StubStep.http(status: 200), .body(Self.sseToolTurn), .finish]
        let (provider, opts, scenario) = try rig([
            [.http(status: 429, headers: ["retry-after": "3"]), .body("{}"), .finish],
            ok,
        ])
        let sleeps = Locked<[TimeInterval]>([])
        let response = try await withRetry(policy: RetryPolicy(maxAttempts: 3),
                                           sleep: { s in sleeps.mutate { $0.append(s) } }) { _ in
            try await provider.completeCollecting(Self.ctx, tools: [], opts: opts)
        }
        #expect(response.stopReason == .toolUse)
        #expect(scenario.requests.value.count == 2)
        #expect(sleeps.value.count == 1)
        #expect(sleeps.value[0] >= 3)  // retry-after es piso del backoff
    }

    // MARK: Errores de transporte

    @Test func errorMidStreamAfterDeltas() async throws {
        let partial = """
            data: {"type":"message_start","message":{"id":"msg_2","model":"claude-opus-4-8"}}
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hola"}}

            """
        let (provider, opts, _) = try rig([[
            .http(status: 200, headers: Self.sseHeaders), .body(partial), .pause(0.2), .fail(.networkConnectionLost),
        ]])
        let seen = Locked<[ProviderEvent]>([])
        var thrown: Error?
        do {
            for try await event in provider.complete(Self.ctx, tools: [], opts: opts) {
                seen.mutate { $0.append(event) }
            }
        } catch {
            thrown = error
        }
        #expect(seen.value == [.messageStart(id: "msg_2", model: "claude-opus-4-8"), .textDelta("Hola")])
        #expect(thrown as? ClassifiedError == .retryable(after: nil))
    }

    @Test func sseErrorEventMidStreamIsClassified() async throws {
        let body = """
            data: {"type":"message_start","message":{"id":"m","model":"claude-opus-4-8"}}
            data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

            """
        let (provider, opts, _) = try rig([[.http(status: 200), .body(body), .finish]])
        let error = await collectError(provider, opts)
        #expect(error as? ClassifiedError == .retryable(after: 10))
    }

    @Test func timeoutIsRetryable() async throws {
        let (provider, opts, _) = try rig([[.fail(.timedOut)]])
        let error = await collectError(provider, opts)
        #expect(error as? ClassifiedError == .retryable(after: nil))
    }

    @Test func nonRetryableTransportErrorPassesThrough() async throws {
        let (provider, opts, _) = try rig([[.fail(.badURL)]])
        let error = await collectError(provider, opts)
        #expect((error as? URLError)?.code == .badURL)
    }

    @Test func buildFailureSurfacesWithoutNetwork() async throws {
        // Un JSONValue con Double no finito no es codificable → el builder falla
        // antes de tocar la red y el error se propaga tal cual.
        let (provider, opts, scenario) = try rig([])
        let tools: [ToolSpec] = [.client(name: "x", description: "d", inputSchema: .double(.nan))]
        var thrown: Error?
        do {
            for try await _ in provider.complete(Self.ctx, tools: tools, opts: opts) {}
        } catch {
            thrown = error
        }
        #expect(thrown != nil)
        #expect(scenario.requests.value.isEmpty)
    }

    // MARK: Cancelación: el consumidor corta → se cancela la conexión

    @Test func consumerCancellationStopsTheConnection() async throws {
        let lines = """
            data: {"type":"message_start","message":{"id":"m3","model":"claude-opus-4-8"}}
            data: {"type":"ping"}

            """
        let (provider, opts, scenario) = try rig([[.http(status: 200, headers: Self.sseHeaders), .body(lines), .hang]])

        let seen = Locked<[ProviderEvent]>([])
        let consumer = Task {
            for try await event in provider.complete(Self.ctx, tools: [], opts: opts) {
                seen.mutate { $0.append(event) }
            }
        }
        for _ in 0..<200 where seen.value.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(seen.value == [.messageStart(id: "m3", model: "claude-opus-4-8")])

        // El dueño cancela el turno: onTermination → task.cancel() → URLSession
        // cancela la conexión (stopLoading del protocolo).
        consumer.cancel()
        for _ in 0..<200 where !scenario.stopped.value {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(scenario.stopped.value)
        _ = await consumer.result
    }
}
