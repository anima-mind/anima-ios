import Foundation
import Testing
@testable import AnimaKit

// MARK: - Sesión local mockeada (CI no tiene FoundationModels garantizado)

/// Reproduce elementos de stream fijos (o lanza un error) y captura el request.
final class MockOnDeviceSession: OnDeviceModelSession, @unchecked Sendable {
    private let scripts: [[OnDeviceStreamElement]]
    private let error: OnDeviceSessionError?
    private let index = Locked(0)
    let requests = Locked<[OnDeviceRequest]>([])

    init(_ scripts: [[OnDeviceStreamElement]] = [], error: OnDeviceSessionError? = nil) {
        self.scripts = scripts
        self.error = error
    }

    func stream(_ request: OnDeviceRequest) -> AsyncThrowingStream<OnDeviceStreamElement, Error> {
        requests.mutate { $0.append(request) }
        let i = index.mutate { current -> Int in let c = current; current += 1; return c }
        let elements = i < scripts.count ? scripts[i] : []
        let error = self.error
        return AsyncThrowingStream { continuation in
            for element in elements { continuation.yield(element) }
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }
}

enum OnDeviceTestConfig {
    static let json = Data("""
    {"on_device":{"api":{"base_url":"local://device","betas":[]},"routes":{
      "interactive":{"model":"\(OnDeviceProvider.modelName)","max_tokens":1500},
      "interactiveHard":{"model":"\(OnDeviceProvider.modelName)","max_tokens":2000},
      "restructure":{"model":"\(OnDeviceProvider.modelName)","max_tokens":2000},
      "consolidation":{"model":"\(OnDeviceProvider.modelName)","max_tokens":1000},
      "reconsolidation":{"model":"\(OnDeviceProvider.modelName)","max_tokens":1000},
      "desirePulse":{"model":"\(OnDeviceProvider.modelName)","max_tokens":600},
      "distill":{"model":"\(OnDeviceProvider.modelName)","max_tokens":1000}}}}
    """.utf8)

    static let prompt = "You are Anima, a personal mind that lives entirely on this phone."

    static func router() throws -> ModelRouter {
        let entry = try #require(try ProviderConfigParser.parse(json)[.onDevice])
        return ModelRouter(config: ProviderConfig(systemPromptBase: prompt, api: entry.api, routes: entry.routes))
    }

    static func opts() throws -> CallOpts {
        let router = try router()
        return CallOpts(route: router.route(.interactive), api: router.api, authMode: .apiKey,
                        token: "", systemPromptBase: router.systemPromptBase)
    }
}

@Suite struct OnDeviceProviderTests {

    private func collect(_ provider: OnDeviceProvider, _ ctx: AssembledContext,
                         tools: [ToolSpec] = []) async throws -> [ProviderEvent] {
        var events: [ProviderEvent] = []
        for try await event in provider.complete(ctx, tools: tools, opts: try OnDeviceTestConfig.opts()) {
            events.append(event)
        }
        return events
    }

    // MARK: snapshot → deltas

    @Test func snapshotTrackerConvertsCumulativeToDeltas() {
        var tracker = SnapshotDeltaTracker()
        #expect(tracker.delta(for: "Ho") == "Ho")
        #expect(tracker.delta(for: "Hola") == "la")
        #expect(tracker.delta(for: "Hola") == "")
        #expect(tracker.delta(for: "Hola, Joshua") == ", Joshua")
        // Reescritura: lo nuevo tras el prefijo común, sin retractar lo mostrado.
        #expect(tracker.delta(for: "Hola, Jo!") == "!")
        #expect(tracker.text == "Hola, Jo!")
    }

    @Test func streamsDeltasAndAssemblesFullText() async throws {
        let session = MockOnDeviceSession([[.snapshot("Ho"), .snapshot("Hola"), .snapshot("Hola, ¿qué tal?")]])
        let provider = OnDeviceProvider(session: session, availability: { .available })
        let events = try await collect(provider, AssembledContext(messages: [.user("hola")]))

        let deltas = events.compactMap { if case .textDelta(let d) = $0 { return d } else { return nil } }
        #expect(deltas == ["Ho", "la", ", ¿qué tal?"])
        guard case .messageStart(_, let model)? = events.first else {
            Issue.record("falta messageStart"); return
        }
        #expect(model == "system_language_model")
        #expect(events.last == .messageStop)

        let again = OnDeviceProvider(session: MockOnDeviceSession([[.snapshot("Hola"), .snapshot("Hola, ¿qué tal?")]]),
                                     availability: { .available })
        let full = try await again.completeCollecting(
            AssembledContext(messages: [.user("hola")]), tools: [], opts: try OnDeviceTestConfig.opts())
        #expect(full.content == [.text("Hola, ¿qué tal?")])
        #expect(full.stopReason == .endTurn)
        #expect(full.model == "system_language_model")
    }

    // MARK: tools (puente nativo con intercepción)

    @Test func interceptedToolCallBecomesToolUseBlock() async throws {
        let session = MockOnDeviceSession([[
            .snapshot("Lo anoto"),
            .toolCall(name: "declare_goal", argumentsJSON: #"{"statement":"leer","checkin":"weekly","hour":20.0}"#),
        ]])
        let provider = OnDeviceProvider(session: session, availability: { .available })
        let response = try await provider.completeCollecting(
            AssembledContext(messages: [.user("quiero leer")]),
            tools: [GoalsTool(otherModel: OtherModel(queue: try AnimaDatabase.temporary())).spec],
            opts: try OnDeviceTestConfig.opts())

        #expect(response.stopReason == .toolUse)
        let call = try #require(response.toolCalls.first)
        // El provider entrega la llamada local tal cual: la traduce el loop.
        #expect(call.name == "declare_goal")
        // 20.0 del framework → .int(20): las tools leen enteros como con Claude.
        #expect(call.input == .object(["statement": .string("leer"), "checkin": .string("weekly"), "hour": .int(20)]))
        #expect(response.content.first == .text("Lo anoto"))

        // La tool viaja en su forma local: una intención, todo obligatorio,
        // hora acotada y sin `action`.
        let request = try #require(session.requests.value.first)
        let tool = try #require(request.tools.first)
        #expect(tool.name == "declare_goal")
        #expect(tool.description.contains("Ej: {statement:"))
        guard case .object(_, _, let properties) = tool.schema else {
            Issue.record("schema raíz no es objeto"); return
        }
        #expect(properties.map(\.name) == ["checkin", "hour", "statement"])
        #expect(properties.allSatisfy { !$0.isOptional })
        #expect(properties.first { $0.name == "hour" }?.schema == .bounded(description: nil, range: 0...23))

        // El schema completo (remotos) sigue traduciendo enums a choices.
        guard case .client(let name, _, let schema) = CalendarTool().spec,
              case .object(_, _, let fullProps) = OnDeviceSchema.from(jsonSchema: schema, name: name) else {
            Issue.record("schema completo"); return
        }
        #expect(fullProps.first { $0.name == "action" }?.schema
                == .string(description: "Operación a realizar.", choices: ["list", "search", "create", "delete"]))
    }

    @Test func serverToolsAreNotExposedLocally() throws {
        let request = OnDevicePromptBuilder.request(
            ctx: AssembledContext(messages: [.user("busca")]),
            tools: [WebSearchTool.spec, CalendarTool().spec], opts: try OnDeviceTestConfig.opts())
        #expect(request.tools.map(\.name) == ["add_calendar_event", "list_events"])
    }

    /// Toda tool real del Sensorimotor traduce su schema (objeto raíz con action).
    @Test func everySensorimotorToolSchemaBridges() {
        let tools: [any SensorimotorTool] = [CalendarTool(), RemindersTool(), NotesTool(),
                                             PhoneContextTool(), CameraTool(), AudioTool()]
        for tool in tools {
            guard case .client(let name, _, let schema) = tool.spec else { continue }
            let bridged = OnDeviceSchema.from(jsonSchema: schema, name: name)
            guard case .object(let root, _, _) = bridged else {
                Issue.record("\(name): raíz no es objeto"); continue
            }
            #expect(root == name)
        }
    }

    // MARK: ensamblado → request local

    @Test func systemMessagesFoldIntoInstructionsAndTailBecomesPrompt() throws {
        let ctx = AssembledContext(messages: [
            .user("hola"),
            .assistant([.text("¿en qué te ayudo?")]),
            Message(role: .system, content: [.text("[SELF] Eres Anima.")]),
            .user("[MEMORIAS ACTIVADAS — pueden estar desactualizadas]\n- vive en Bogotá"),
            .user("¿dónde vivo?"),
        ])
        let request = OnDevicePromptBuilder.request(ctx: ctx, tools: [], opts: try OnDeviceTestConfig.opts())
        #expect(request.instructions == OnDeviceTestConfig.prompt + "\n\n[SELF] Eres Anima.")
        #expect(request.history == [.prompt("hola"), .response("¿en qué te ayudo?")])
        #expect(request.prompt == "[MEMORIAS ACTIVADAS — pueden estar desactualizadas]\n- vive en Bogotá\n\n¿dónde vivo?")
        #expect(request.maxResponseTokens == 1500)
    }

    /// Tras una ronda de tools exitosa el 3B solo redacta: la ronda se pliega a
    /// texto sobre el turno del dueño, sin tools y con fallback determinista.
    @Test func successfulToolRoundFoldsIntoThePromptWithoutTools() throws {
        let ctx = AssembledContext(messages: [
            Message(role: .system, content: [.text("[SELF]")]),
            .user("hola"),
            .assistant([.text("¡hola!")]),
            .user("recuérdame mañana a las 9 llamar al banco"),
            .assistant([.toolUse(id: "t1", name: "remind_me", input: .object(["text": .string("llamar al banco")]))]),
            .user([.toolResult(toolUseId: "t1", content: "Listo: te recuerdo 'llamar al banco' mañana. Id AB-12.",
                               isError: false)]),
        ])
        let request = OnDevicePromptBuilder.request(ctx: ctx, tools: try RealToolSet.specs(),
                                                    opts: try OnDeviceTestConfig.opts())
        #expect(request.history == [.prompt("hola"), .response("¡hola!")])
        #expect(request.prompt == OnDevicePromptBuilder.quotedOwner("recuérdame mañana a las 9 llamar al banco") + "\n"
                + OnDevicePromptBuilder.successPrompt(results: ["Listo: te recuerdo 'llamar al banco' mañana. Id AB-12."]))
        #expect(request.tools.isEmpty)
        #expect(request.fallbackText == "Listo, te recuerdo 'llamar al banco' mañana.")
    }

    @Test func readToolRoundAnswersWithWhatItRead() throws {
        let ctx = AssembledContext(messages: [
            .user("¿qué recordatorios tengo?"),
            .assistant([.toolUse(id: "t1", name: "list_reminders", input: .object([:]))]),
            .user([.toolResult(toolUseId: "t1", content: "Programados:\n- llamar al banco", isError: false)]),
        ])
        let request = OnDevicePromptBuilder.request(ctx: ctx, tools: [], opts: try OnDeviceTestConfig.opts())
        #expect(request.prompt.hasSuffix(OnDevicePromptBuilder.readPrompt(results: ["Programados:\n- llamar al banco"])))
        #expect(request.fallbackText == "Programados:\n- llamar al banco")
    }

    @Test func imagesDegradeToPlaceholder() throws {
        let ctx = AssembledContext(messages: [.user([.text("mira"), .image(mediaType: "image/jpeg", base64: "AAAA")])])
        let request = OnDevicePromptBuilder.request(ctx: ctx, tools: [], opts: try OnDeviceTestConfig.opts())
        #expect(request.prompt == "mira\n" + OnDevicePromptBuilder.imagePlaceholder)
    }

    // MARK: errores

    @Test func guardrailBecomesRefusalNotError() async throws {
        let provider = OnDeviceProvider(session: MockOnDeviceSession(error: .guardrailViolation),
                                        availability: { .available })
        let response = try await provider.completeCollecting(
            AssembledContext(messages: [.user("algo")]), tools: [], opts: try OnDeviceTestConfig.opts())
        #expect(response.stopReason == .refusal)
    }

    @Test func contextOverflowIsClassified() async throws {
        let provider = OnDeviceProvider(session: MockOnDeviceSession(error: .exceededContextWindow),
                                        availability: { .available })
        await #expect(throws: ClassifiedError.contextOverflow) {
            _ = try await provider.completeCollecting(
                AssembledContext(messages: [.user("x")]), tools: [], opts: try OnDeviceTestConfig.opts())
        }
    }

    @Test func otherErrorsAreFatalNonRetryable() {
        #expect(OnDeviceProvider.classify(.other("boom")) == .fatal(status: OnDeviceProvider.failureStatus, message: "boom"))
        #expect(OnDeviceProvider.classify(.assetsUnavailable)
                == .fatal(status: OnDeviceProvider.unavailableStatus, message: OnDeviceAvailability.modelNotReady.reason!))
    }

    @Test func unavailableModelFailsFastWithReason() async throws {
        let session = MockOnDeviceSession([[.snapshot("no debería")]])
        let provider = OnDeviceProvider(session: session, availability: { .appleIntelligenceOff })
        await #expect(throws: ClassifiedError.fatal(status: OnDeviceProvider.unavailableStatus,
                                                    message: OnDeviceAvailability.appleIntelligenceOff.reason!)) {
            _ = try await provider.completeCollecting(
                AssembledContext(messages: [.user("x")]), tools: [], opts: try OnDeviceTestConfig.opts())
        }
        #expect(session.requests.value.isEmpty)   // ni siquiera se intentó
    }

    // MARK: availability → UI

    @Test func availabilityStatesExplainWhy() {
        #expect(OnDeviceAvailability.available.isAvailable)
        #expect(OnDeviceAvailability.available.reason == nil)
        for state in OnDeviceAvailability.allCases where state != .available {
            #expect(!state.isAvailable)
            #expect(state.reason?.isEmpty == false)
        }
        #expect(OnDeviceAvailability.modelNotReady.label.contains("descargando"))
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// Con el SDK disponible (Xcode 26+), el puente real construye un
/// `GenerationSchema` válido para cada tool del Sensorimotor (sin tocar el modelo).
@Suite struct OnDeviceSchemaBridgeTests {
    @Test func realGenerationSchemasBuildForEveryTool() throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let tools: [any SensorimotorTool] = [CalendarTool(), RemindersTool(), NotesTool(),
                                             PhoneContextTool(), CameraTool(), AudioTool()]
        for tool in tools {
            guard case .client(let name, _, let schema) = tool.spec else { continue }
            _ = try OnDeviceSchemaBridge.generationSchema(for: OnDeviceSchema.from(jsonSchema: schema, name: name))
        }
    }

    /// Smoke contra el modelo real — opt-in (`ANIMA_FM_SMOKE=1`) y solo si el Mac
    /// tiene Apple Intelligence: verifica streaming + intercepción de tools.
    @Test func realModelSmoke() async throws {
        guard ProcessInfo.processInfo.environment["ANIMA_FM_SMOKE"] == "1" else { return }
        guard #available(iOS 26.0, macOS 26.0, *), OnDeviceAvailability.current().isAvailable else { return }
        let provider = OnDeviceProvider.system()
        let text = try await provider.completeCollecting(
            AssembledContext(messages: [.user("Di hola en una frase corta.")]),
            tools: [], opts: try OnDeviceTestConfig.opts())
        print("[FM smoke] texto:", text.content, text.stopReason as Any)
        let tool = try await provider.completeCollecting(
            AssembledContext(messages: [.user("¿Qué eventos tengo en el calendario los próximos 3 días? Usa la herramienta calendar.")]),
            tools: [CalendarTool().spec], opts: try OnDeviceTestConfig.opts())
        print("[FM smoke] tool:", tool.content, tool.stopReason as Any)
    }
}
#endif
