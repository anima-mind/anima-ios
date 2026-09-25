import Foundation
import Testing
@testable import AnimaKit

/// Sesión que emite elementos y termina con un error arbitrario (no solo
/// OnDeviceSessionError): para las ramas de cancelación y fallo genérico.
struct ThrowingOnDeviceSession: OnDeviceModelSession {
    let elements: [OnDeviceStreamElement]
    let error: any Error & Sendable
    func stream(_ request: OnDeviceRequest) -> AsyncThrowingStream<OnDeviceStreamElement, Error> {
        AsyncThrowingStream { continuation in
            for element in elements { continuation.yield(element) }
            continuation.finish(throwing: error)
        }
    }
}

@Suite struct OnDeviceProviderEdgeTests {

    private func events(_ session: any OnDeviceModelSession,
                        _ ctx: AssembledContext = AssembledContext(messages: [.user("hola")])) async throws -> [ProviderEvent] {
        let provider = OnDeviceProvider(session: session, availability: { .available })
        var out: [ProviderEvent] = []
        for try await event in provider.complete(ctx, tools: [], opts: try OnDeviceTestConfig.opts()) {
            out.append(event)
        }
        return out
    }

    // MARK: Mapeo de errores del framework

    @Test func refusalAfterPartialTextClosesTheTextBlock() async throws {
        let session = MockOnDeviceSession([[.snapshot("Mira, ")]], error: .refusal)
        let out = try await events(session)
        #expect(out.contains(.textDelta("Mira, ")))
        let tail = Array(out.suffix(3))
        #expect(tail.first == .blockStop(index: 0))
        if case .messageDelta(let stop, _) = tail[1] { #expect(stop == .refusal) } else { Issue.record("sin messageDelta") }
        #expect(tail.last == .messageStop)
    }

    @Test func unsupportedLanguageAndAssetsAreFatal() async throws {
        #expect(OnDeviceProvider.classify(.unsupportedLanguage)
                == .fatal(status: OnDeviceProvider.failureStatus, message: "El modelo local no soporta este idioma."))
        // guardrail/refusal que se clasifican fuera del stream (p. ej. en el Híbrido).
        #expect(OnDeviceProvider.classify(.refusal)
                == .fatal(status: OnDeviceProvider.failureStatus, message: "El modelo local declinó responder."))

        await #expect(throws: ClassifiedError.fatal(status: OnDeviceProvider.failureStatus,
                                                    message: "El modelo local no soporta este idioma.")) {
            _ = try await events(MockOnDeviceSession(error: .unsupportedLanguage))
        }
    }

    @Test func unsupportedBuildSessionReportsModelNotReady() async throws {
        await #expect(throws: ClassifiedError.fatal(status: OnDeviceProvider.unavailableStatus,
                                                    message: OnDeviceAvailability.modelNotReady.reason!)) {
            _ = try await events(UnsupportedOnDeviceSession())
        }
    }

    @Test func foreignErrorsBecomeFatalFailure() async throws {
        let error = StoreFailure(message: "XPC interrumpido")
        await #expect(throws: ClassifiedError.fatal(status: OnDeviceProvider.failureStatus, message: "XPC interrumpido")) {
            _ = try await events(ThrowingOnDeviceSession(elements: [], error: error))
        }
    }

    @Test func cancellationPropagatesAsCancellation() async throws {
        await #expect(throws: CancellationError.self) {
            _ = try await events(ThrowingOnDeviceSession(elements: [.snapshot("a")], error: CancellationError()))
        }
    }

    // MARK: Intercepción de tools

    @Test func textThenToolCallUsesSeparateBlocksAndNormalizesIntegers() async throws {
        let session = MockOnDeviceSession([[
            .snapshot("Reviso tu agenda."),
            .toolCall(name: "calendar", argumentsJSON: #"{"action":"list","days_ahead":3.0,"ratio":0.5,"tags":[1.0,"x"]}"#),
        ]])
        let out = try await events(session)
        #expect(out.contains(.blockStop(index: 0)))
        #expect(out.contains(.blockStop(index: 1)))
        let input = out.compactMap { if case .toolUseInputDelta(let s) = $0 { return s } else { return nil } }.first
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(input).utf8))
        #expect(parsed["days_ahead"] == .int(3))
        #expect(parsed["ratio"] == .double(0.5))
        #expect(parsed["tags"] == .array([.int(1), .string("x")]))
        #expect(out.contains { if case .toolUseStart(let id, "calendar") = $0 { return id.hasPrefix("toolu_ondevice_") } else { return false } })
    }

    @Test func malformedToolArgumentsDegradeToEmptyObject() {
        #expect(OnDevicePromptBuilder.normalizeArguments("{no json") == .object([:]))
        #expect(OnDevicePromptBuilder.normalizeArguments(#"{"n":-2.0,"big":1e300}"#)
                == .object(["n": .int(-2), "big": .double(1e300)]))
    }

    // MARK: Reconstrucción del transcript

    @Test func multipleToolResultsMapBackToTheirToolNames() throws {
        let ctx = AssembledContext(messages: [
            .user("¿Qué tengo hoy y qué recordatorios hay?"),
            Message(role: .assistant, content: [
                .thinking("pienso"),
                .text("Consulto."),
                .toolUse(id: "t1", name: "calendar", input: .object(["action": .string("list")])),
                .toolUse(id: "t2", name: "reminders", input: .object(["action": .string("list")])),
            ]),
            Message(role: .user, content: [
                .thinking("x"),
                .toolResult(toolUseId: "t1", content: "- reunión 10am", isError: false),
                .toolResult(toolUseId: "t2", content: "sin permiso", isError: true),
                .toolResult(toolUseId: "t9", content: "huérfano", isError: false),
            ]),
        ])
        let request = OnDevicePromptBuilder.request(ctx: ctx, tools: [], opts: try OnDeviceTestConfig.opts())
        #expect(request.history == [
            .prompt("¿Qué tengo hoy y qué recordatorios hay?"),
            .response("Consulto."),
            .toolCall(id: "t1", name: "calendar", argumentsJSON: #"{"action":"list"}"#),
            .toolCall(id: "t2", name: "reminders", argumentsJSON: #"{"action":"list"}"#),
            .toolOutput(id: "t1", name: "calendar", content: "- reunión 10am"),
            .toolOutput(id: "t2", name: "reminders", content: "ERROR: sin permiso"),
            .toolOutput(id: "t9", name: "tool", content: "huérfano"),
        ])
        #expect(request.prompt == OnDevicePromptBuilder.continuationCue)
        #expect(OnDevicePromptBuilder.estimateTokens(request) > 0)
    }

    @Test func consecutiveUserTurnsMergeIntoOnePrompt() throws {
        let ctx = AssembledContext(messages: [
            .user("memoria: vive en Bogotá"),
            .user("¿qué clima hace?"),
        ])
        let request = OnDevicePromptBuilder.request(ctx: ctx, tools: [], opts: try OnDeviceTestConfig.opts())
        #expect(request.history.isEmpty)
        #expect(request.prompt == "memoria: vive en Bogotá\n\n¿qué clima hace?")
    }

    // MARK: JSON Schema → OnDeviceSchema

    @Test func schemaTranslatesEveryPrimitiveAndDegradesUnknowns() {
        let schema = JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "ratio": .object(["type": .string("number"), "description": .string("r")]),
                "flag": .object(["type": .string("boolean")]),
                "tags": .object(["type": .string("array"), "items": .object(["type": .string("integer")])]),
                "loose": .object(["type": .string("array")]),
                "mode": .object(["type": .string("string"), "enum": .array([])]),
                "weird": .object(["type": .string("null")]),
            ]),
            "required": .array([.string("flag")]),
        ])
        guard case .object(_, _, let props) = OnDeviceSchema.from(jsonSchema: schema, name: "t") else {
            Issue.record("no es object"); return
        }
        let byName = Dictionary(uniqueKeysWithValues: props.map { ($0.name, $0) })
        #expect(byName["ratio"]?.schema == .number(description: "r"))
        #expect(byName["flag"]?.schema == .boolean(description: nil))
        #expect(byName["flag"]?.isOptional == false)
        #expect(byName["tags"]?.schema == .array(description: nil, items: .integer(description: nil)))
        #expect(byName["loose"]?.schema == .array(description: nil, items: .string(description: nil, choices: nil)))
        #expect(byName["mode"]?.schema == .string(description: nil, choices: nil))  // enum vacío = libre
        #expect(byName["weird"]?.schema == .string(description: nil, choices: nil))
        #expect(props.map(\.name) == ["flag", "loose", "mode", "ratio", "tags", "weird"])
    }
}

#if canImport(FoundationModels)
import FoundationModels

@Suite struct OnDeviceFoundationModelsBridgeTests {

    @Test func bridgeBuildsNumberBooleanAndArraySchemas() throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let schema = OnDeviceSchema.object(name: "args", description: "d", properties: [
            .init(name: "ratio", description: nil, schema: .number(description: nil), isOptional: true),
            .init(name: "flag", description: nil, schema: .boolean(description: nil), isOptional: false),
            .init(name: "tags", description: nil,
                  schema: .array(description: nil, items: .string(description: nil, choices: ["a", "b"])),
                  isOptional: true),
        ])
        _ = try OnDeviceSchemaBridge.generationSchema(for: schema)
        // Raíz no-object: nombre por defecto.
        _ = try OnDeviceSchemaBridge.generationSchema(for: .array(description: nil, items: .integer(description: nil)))
    }

    @Test func interceptingToolThrowsInsteadOfExecuting() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let tool = InterceptingTool(name: "calendar", description: "d",
                                    parameters: try OnDeviceSchemaBridge.generationSchema(
                                        for: .object(name: "calendar", description: nil, properties: [])))
        do {
            _ = try await tool.call(arguments: try GeneratedContent(json: #"{"action":"list"}"#))
            Issue.record("la tool ejecutó")
        } catch let interception as OnDeviceToolInterception {
            #expect(interception.name == "calendar")
            #expect(interception.argumentsJSON.contains("list"))
        }
    }

    @Test func transcriptGroupsConsecutiveToolCalls() throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let request = OnDeviceRequest(
            instructions: "Eres Anima.",
            history: [
                .prompt("hola"),
                .response("¿en qué te ayudo?"),
                .prompt("agenda y recordatorios"),
                .toolCall(id: "t1", name: "calendar", argumentsJSON: #"{"action":"list"}"#),
                .toolCall(id: "t2", name: "reminders", argumentsJSON: "no-json"),
                .toolOutput(id: "t1", name: "calendar", content: "nada"),
                .toolOutput(id: "t2", name: "reminders", content: "nada"),
                .toolCall(id: "t3", name: "notes", argumentsJSON: "{}"),
            ],
            prompt: OnDevicePromptBuilder.continuationCue, tools: [], maxResponseTokens: 100)
        let transcript = SystemOnDeviceModelSession.transcript(for: request, tools: [])
        let kinds: [String] = transcript.map { entry in
            switch entry {
            case .instructions: return "instructions"
            case .prompt: return "prompt"
            case .response: return "response"
            case .toolCalls(let calls): return "toolCalls(\(calls.count))"
            case .toolOutput: return "toolOutput"
            @unknown default: return "?"
            }
        }
        #expect(kinds == ["instructions", "prompt", "response", "prompt", "toolCalls(2)",
                          "toolOutput", "toolOutput", "toolCalls(1)"])
    }

    @Test func generationErrorsMapToHarnessTaxonomy() {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let ctx = LanguageModelSession.GenerationError.Context(debugDescription: "x")
        #expect(SystemOnDeviceModelSession.map(.exceededContextWindowSize(ctx)) == .exceededContextWindow)
        #expect(SystemOnDeviceModelSession.map(.guardrailViolation(ctx)) == .guardrailViolation)
        #expect(SystemOnDeviceModelSession.map(.assetsUnavailable(ctx)) == .assetsUnavailable)
        #expect(SystemOnDeviceModelSession.map(.unsupportedLanguageOrLocale(ctx)) == .unsupportedLanguage)
        if case .other = SystemOnDeviceModelSession.map(.rateLimited(ctx)) {} else { Issue.record("rateLimited debería ser .other") }
    }
}
#endif
