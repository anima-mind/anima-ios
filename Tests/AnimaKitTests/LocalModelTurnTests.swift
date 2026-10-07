import Foundation
import Testing
@testable import AnimaKit

// El modelo local con el set del adapter, de punta a punta con
// providers guionados (sin el framework).

/// Un turno del AgentLoop con un provider guionado.
enum LocalLoopHarness {
    static func toolUse(_ id: String, _ name: String, _ json: String, model: String = "claude-opus-4-8") -> [ProviderEvent] {
        [.messageStart(id: id, model: model), .toolUseStart(id: id, name: name), .toolUseInputDelta(json),
         .blockStop(index: 0), .messageDelta(stopReason: .toolUse, usage: Usage()), .messageStop]
    }

    static func text(_ s: String) -> [ProviderEvent] {
        [.messageStart(id: "t", model: "claude-opus-4-8"), .textDelta(s), .blockStop(index: 0),
         .messageDelta(stopReason: .endTurn, usage: Usage()), .messageStop]
    }

    struct Run {
        var events: [LoopEvent]
        var store: SymbolicStore
        var sid: SessionID
        var text: String {
            events.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }.joined()
        }
        func lastAssistantText() throws -> String {
            let window = try store.window(sessionId: sid)
            return OnDevicePromptBuilder.plainText(window.last { $0.role == .assistant }?.content ?? [])
        }
    }

    static func run(_ scripts: [[ProviderEvent]], tools: [any SensorimotorTool], router: ModelRouter? = nil,
                    policy: PermissionPolicy = .init(), text: String = "hazlo") async throws -> Run {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let loop = AgentLoop(provider: ScriptedProvider(scripts), store: store, telemetry: Telemetry(queue: queue),
                             router: try router ?? ModelRouter(config: TestConfig.providerConfig()),
                             authMode: .apiKey, token: "sk-ant-api03-x", clientTools: tools, serverTools: [],
                             permissionPolicy: policy, sleep: { _ in })
        let sid = try store.startSession()
        var events: [LoopEvent] = []
        for await event in await loop.run(sessionId: sid, userText: text) { events.append(event) }
        return Run(events: events, store: store, sid: sid)
    }

    static func notesRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

}

@Suite struct LocalModelTurnTests {
    @Test func theLocalModelExecutesTheTranslatedCall() async throws {
        let w = try ProactiveFixtures.world()
        let model = OnDeviceProvider.modelName
        let r = try await LocalLoopHarness.run([
            LocalLoopHarness.toolUse("a", "remind_me", #"{"text":"llamar al banco","when":"2030-01-02 09:00","repeat":"none"}"#,
                         model: model),
            LocalLoopHarness.text("Listo, te lo recuerdo."),
        ], tools: [AnimaRemindersTool(store: w.reminders)], router: try OnDeviceTestConfig.router(),
           policy: .app(ownerAllowlist: { [] }))
        #expect(r.events.contains(.toolStarted(name: "anima_reminders")))
        #expect(r.events.contains(.toolFinished(name: "anima_reminders", isError: false)))
        let reminder = try #require(await w.reminders.list().first)
        #expect(reminder.text == "llamar al banco")
        #expect(Calendar.current.component(.hour, from: reminder.fireAt) == 9)
        // El transcript conserva lo que dijo el modelo.
        let window = try r.store.window(sessionId: r.sid)
        #expect(window.contains { $0.content.contains { if case .toolUse(_, "remind_me", _) = $0 { true } else { false } } })
    }

}

/// El medidor del router de tests local: la ventana del modelo de Apple, no la de Claude.
@Suite struct LocalRouterGaugeTests {
    @Test func theTestRouterIsTheLocalModel() async throws {
        let router = try OnDeviceTestConfig.router()
        #expect(OnDeviceProvider.isOnDevice(model: router.route(.interactive).model))
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let loop = AgentLoop(provider: ScriptedProvider([LocalLoopHarness.text("hola")]), store: store,
                             telemetry: Telemetry(queue: queue), router: router, authMode: .apiKey, token: "",
                             clientTools: [], serverTools: [WebSearchTool.spec], sleep: { _ in })
        let sid = try store.startSession()
        var budgets: [Int] = []
        for await event in await loop.run(sessionId: sid, userText: "hola") {
            if case .context(let gauge) = event { budgets.append(gauge.budgetTokens) }
        }
        #expect(budgets == [4096])
        let gauge = try #require(await loop.contextGauge(sessionId: sid))
        #expect(gauge.budgetTokens == 4096 && gauge.model == "Modelo local (Apple)")
        #expect(ProviderSelector.claudeOnly(provider: ScriptedProvider([]), router: router, authMode: .apiKey,
                                            token: "").conversationProfile == .onDevice)
    }
}

/// Tras tools exitosas el texto local no se streamea a medias: si el modelo
/// no logra redactar (guardrail), la confirmación determinista.
@Suite struct OnDeviceSuccessFallbackTests {
    static let ctx = AssembledContext(messages: [
        .user("quiero bajar 5 kilos"),
        .assistant([.toolUse(id: "t1", name: "declare_goal", input: .object([:]))]),
        .user([.toolResult(toolUseId: "t1", content: "Meta registrada (id G-1): bajar 5 kilos. Te pregunto cada lunes a las 20:00.",
                           isError: false)]),
    ])

    @Test(arguments: [OnDeviceSessionError.guardrailViolation, .refusal, .other("x"), .assetsUnavailable])
    func aGuardrailAfterSuccessBecomesTheConfirmation(error: OnDeviceSessionError) async throws {
        let session = MockOnDeviceSession([[.snapshot("Listo, ya registré la meta de baj")]], error: error)
        let provider = OnDeviceProvider(session: session, availability: { .available })
        let deltas = Locked<[String]>([])
        let response = try await provider.completeCollecting(Self.ctx, tools: [], opts: try OnDeviceTestConfig.opts()) {
            if case .textDelta(let d) = $0 { deltas.mutate { $0.append(d) } }
        }
        let expected = "Listo: Meta registrada: bajar 5 kilos. Te pregunto cada lunes a las 20:00."
        #expect(deltas.value == [expected])
        #expect(response.content == [.text(expected)])
        #expect(response.stopReason == .endTurn)
    }

    @Test func aGoodAnswerIsDeliveredWholeAndAToolCallIsIgnored() async throws {
        let session = MockOnDeviceSession([[.snapshot("Listo,"), .snapshot("Listo, quedó tu meta."),
                                            .toolCall(name: "declare_goal", argumentsJSON: "{}")]])
        let provider = OnDeviceProvider(session: session, availability: { .available })
        let deltas = Locked<[String]>([])
        let response = try await provider.completeCollecting(Self.ctx, tools: [], opts: try OnDeviceTestConfig.opts()) {
            if case .textDelta(let d) = $0 { deltas.mutate { $0.append(d) } }
        }
        #expect(deltas.value == ["Listo, quedó tu meta."])
        #expect(response.stopReason == .endTurn)
        #expect(response.toolCalls.isEmpty)
        let request = try #require(session.requests.value.first)
        #expect(request.tools.isEmpty)
    }

    @Test func contextOverflowStillPropagates() async throws {
        let session = MockOnDeviceSession([[]], error: .exceededContextWindow)
        let provider = OnDeviceProvider(session: session, availability: { .available })
        await #expect(throws: ClassifiedError.contextOverflow) {
            _ = try await provider.completeCollecting(Self.ctx, tools: [], opts: try OnDeviceTestConfig.opts())
        }
    }

    @Test func confirmationStripsInternalIds() {
        #expect(OnDevicePromptBuilder.confirmation(results: ["Listo: te recuerdo 'x' mañana. Id AB-12."])
                == "Listo, te recuerdo 'x' mañana.")
        #expect(OnDevicePromptBuilder.confirmation(results: ["Anotado en tu nota 'c': pan."]) == "Listo: Anotado en tu nota 'c': pan.")
    }
}
