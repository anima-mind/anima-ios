import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import Testing
@testable import AnimaKit

// Batch 5b #4/#5: "cambié a mitad de la conversación por el modelo de Apple y se
// jodió… Reintentar no hacía nada". Recorte duro determinista, medidor %,
// compactar y nueva conversación.

@Suite struct HardTrimTests {
    static func long(_ n: Int) -> String { String(repeating: "palabra ", count: n) }

    static func conversation(turns: Int, size: Int) -> [Message] {
        var out: [Message] = []
        for i in 0..<turns {
            out.append(.user("pregunta \(i) " + long(size)))
            out.append(.assistant([.text("respuesta \(i) " + long(size))]))
        }
        return out
    }

    static func tail(_ text: String, memories: Bool = true) -> [Message] {
        var out: [Message] = [Message(role: .system, content: [.text("Soy Anima.")])]
        if memories { out.append(.user(WorkingMemory.activatedMemoriesHeader + "\n- " + long(300))) }
        out.append(.user(text))
        return out
    }

    @Test(arguments: [200, 600, 1500, 4000])
    func alwaysFitsAndKeepsTheOwnersLastTurn(budget: Int) {
        let messages = Self.conversation(turns: 12, size: 120) + Self.tail("¿y ahora qué hago?")
        let result = HardTrim.apply(messages, availableTokens: budget)
        #expect(result.didTrim)
        #expect(LocalRelief.estimateTokens(result.messages) <= max(64, budget))
        #expect(result.messages.last == .user("¿y ahora qué hago?"))
        #expect(result.messages.contains { $0.role == .system })
        #expect(result.keptHistory + result.droppedHistory == 24)
        if let first = result.messages.first(where: { $0.role != .system }), result.keptHistory > 0 {
            #expect(first.role == .user)
        }
    }

    @Test func dropsActivatedMemoriesBeforeHistoryAndTruncatesAHugeTurn() {
        let messages = Self.conversation(turns: 2, size: 20) + Self.tail("cuéntame")
        let fits = HardTrim.apply(messages, availableTokens: 100_000)
        #expect(!fits.didTrim && fits.messages == messages)

        let huge = Self.tail(Self.long(3000), memories: true)
        let result = HardTrim.apply(huge, availableTokens: 600)
        #expect(!result.messages.contains(where: HardTrim.isActivatedContext))
        #expect(LocalRelief.estimateTokens(result.messages) <= 600)
        guard case .text(let t)? = result.messages.last?.content.first else { Issue.record("sin turno"); return }
        #expect(t.hasSuffix(HardTrim.truncationMark))
    }

    @Test func neverOpensWithAnOrphanToolResult() {
        let history: [Message] = [
            .user("hola"),
            .assistant([.toolUse(id: "t1", name: "calendar", input: .null)]),
            Message(role: .user, content: [.toolResult(toolUseId: "t1", content: Self.long(10), isError: false)]),
            .assistant([.text("listo")]),
        ]
        let result = HardTrim.apply(history + Self.tail("otra cosa", memories: false),
                                    availableTokens: LocalRelief.estimateTokens(Self.tail("otra cosa", memories: false)) + 20)
        let firstNonSystem = result.messages.first { $0.role != .system }
        #expect(firstNonSystem.map { $0.role == .user && !HardTrim.isOnlyToolResults($0) } ?? true)
    }
}

@Suite struct ContextGaugeTests {
    @Test func percentAndLevelsPerModel() {
        let messages: [Message] = [Message(role: .system, content: [.text(String(repeating: "x", count: 360))]),
                                   .user(WorkingMemory.activatedMemoriesHeader + String(repeating: "m", count: 324)),
                                   .user(String(repeating: "c", count: 3600))]
        let local = ContextGauge.measure(messages, systemBase: String(repeating: "s", count: 3600), tools: [],
                                         model: "Modelo local (Apple)", budgetTokens: ContextProfile.onDevice.contextBudgetTokens)
        #expect(local.systemTokens == 1000 + 100)
        #expect(local.memoryTokens == Int(Double(WorkingMemory.activatedMemoriesHeader.count + 324) / 3.6))
        #expect(local.conversationTokens == 1000)
        #expect(local.roomTokens == 4096 - 1000 - 100)
        #expect(local.level == .normal && (36...38).contains(local.percent))
        let claude = ContextGauge.measure(messages, systemBase: "", tools: [], model: "Claude Opus 4.8",
                                          budgetTokens: ContextProfile.claude.contextBudgetTokens)
        #expect(claude.percent == 1)
        #expect(ContextGauge(model: "", budgetTokens: 100, systemTokens: 0, memoryTokens: 75, conversationTokens: 0).level == .high)
        #expect(ContextGauge(model: "", budgetTokens: 100, systemTokens: 95, memoryTokens: 0, conversationTokens: 50).level == .critical)
        #expect(ContextGauge(model: "", budgetTokens: 100, systemTokens: 95, memoryTokens: 0, conversationTokens: 50).fraction == 1)
        #expect(ContextGauge(model: "", budgetTokens: 0, systemTokens: 5, memoryTokens: 0, conversationTokens: 0).fraction == 0)
        #expect(ContextGauge(model: "", budgetTokens: 100, systemTokens: 95, memoryTokens: 0, conversationTokens: 0).level == .normal)
        #expect(local.summary == "1.1k de 3k tokens para conversar")
        #expect(ContextGauge.compact(999) == "999" && ContextGauge.compact(4000) == "4k")
        #expect(ContextGauge.toolChars([.client(name: "a", description: "bb", inputSchema: .object([:]))]) == 5)
    }

    @Test func toolCostIsMeasuredPerProvider() async throws {
        let tools = try RealToolSet.specs()
        let chars = ContextGauge.toolChars(tools)
        #expect(ContextBudget.for(model: OnDeviceProvider.modelName) == .onDevice)
        #expect(ContextBudget.for(model: "claude-opus-4-8") == .remote)
        #expect(ContextBudget.remote.toolTokens(tools) == Int(Double(chars) / 4.2))
        #expect(ContextBudget.onDevice.toolTokens(tools) == Int(Double(chars) / 2.5))
        let server: ToolSpec = .server(type: "web_search_20260209", name: "web_search")
        #expect(ContextBudget.remote.toolTokens(tools + [server]) > ContextBudget.remote.toolTokens(tools))
        #expect(ContextBudget.onDevice.toolTokens(tools + [server]) == ContextBudget.onDevice.toolTokens(tools))
        #expect(ContextBudget.remote.fixedTokens(systemBase: String(repeating: "s", count: 36), tools: []) == 10)
    }

    /// Medición real (Foundation Models, macOS 26.5, 2026-10-05): las 10 tools
    /// cuestan 3797 tokens en la ventana de 4096 del modelo local — el schema
    /// completo SÍ entra (como `GenerationSchema`, enums expandidos a anyOf). La
    /// estimación de `ContextBudget.onDevice` queda a ±10 % de eso.
    static let measuredOnDeviceToolTokens = 3797

    @Test func onDeviceEstimateMatchesTheFrameworkTokenizer() async throws {
        let tools = try RealToolSet.specs()
        let estimate = ContextBudget.onDevice.toolTokens(tools)
        #expect(abs(estimate - Self.measuredOnDeviceToolTokens) <= Self.measuredOnDeviceToolTokens / 10)
        if let real = await RealToolSet.frameworkTokenCount(tools) {
            #expect(abs(estimate - real) <= real / 10, "estimado \(estimate) vs real \(real)")
        }
    }

    @Test func emptyChatDoesNotAlarmTheMeterWithTheRealTools() throws {
        let tools = try RealToolSet.specs()
        let system = [Message(role: .system, content: [.text("Ahora: lunes 5 de octubre, 8:30 p. m.")])]
        let localRoute = try OnDeviceTestConfig.router().route(.interactive)
        let local = ContextFit(profile: .onDevice, systemBase: AppGuide.systemBase("Eres Anima.", contextBudget: 4096),
                               tools: tools, route: localRoute)
        // Lo fijo ya excede la ventana local: el recorte se queda en el piso.
        #expect(local.fixedTokens > 3000)
        #expect(local.availableTokens == ContextFit.minAvailableTokens)
        let empty = local.gauge(system)
        #expect(empty.percent == 0 && empty.level == .normal)
        #expect(empty.systemTokens >= local.fixedTokens)
        let oneTurn = local.gauge(system + [.user("hola"), .assistant([.text("¡Hola! ¿Cómo vas?")])])
        #expect(oneTurn.level == .normal && oneTurn.percent < 35)

        let claudeRoute = ModelRoute(model: "claude-opus-4-8", effort: "medium", maxTokens: 16_000)
        let claude = ContextFit(profile: .claude, systemBase: AppGuide.systemBase("Eres Anima."), tools: tools,
                                route: claudeRoute)
        #expect(claude.gauge(system).percent == 0)
        #expect(claude.availableTokens == 180_000 - claude.fixedTokens - 16_000)
    }

    @Test func compactGuideForSmallWindows() {
        #expect(AppGuide.systemBase("B", contextBudget: ContextProfile.onDevice.contextBudgetTokens)
                == "B\n\n" + AppGuide.compactBlock)
        #expect(AppGuide.systemBase("B", contextBudget: ContextProfile.claude.contextBudgetTokens) == "B\n\n" + AppGuide.block)
        for tab in ShellTab.allCases { #expect(AppGuide.compactBlock.contains(tab.title)) }
        for route in SettingsRoute.allCases { #expect(AppGuide.compactBlock.contains(route.title)) }
    }
}

@Suite struct ContextLifecycleTests {
    static func localSelector(_ provider: Provider) throws -> ProviderSelector {
        ProviderSelector(mode: .onDeviceOnly, remote: nil,
                         local: .init(provider: provider, router: try OnDeviceTestConfig.router()),
                         availability: { .available })
    }

    /// Una conversación larga con Claude → el mismo transcript con el modelo de Apple.
    static func longSession(_ store: SymbolicStore) throws -> SessionID {
        let sid = try store.startSession()
        for i in 0..<10 {
            try store.append(sessionId: sid, message: .user("pregunta \(i) " + HardTrimTests.long(150)))
            try store.append(sessionId: sid, message: .assistant([.text("## Plan \(i)\n" + HardTrimTests.long(400))]))
        }
        return sid
    }

    @Test func switchingToTheLocalModelTrimsInsteadOfFailing() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let sid = try Self.longSession(store)
        // El último mensaje de Claude (un plan con tabla) ya no cabe solo en ~4k.
        try store.append(sessionId: sid, message: .assistant([.text("## Plan final\n" + HardTrimTests.long(2500))]))
        let provider = CapturingProvider([.text("Te sigo.")])
        let loop = AgentLoop(selector: try Self.localSelector(provider), store: store,
                             telemetry: Telemetry(queue: queue), clientTools: [], sleep: { _ in })
        var events: [LoopEvent] = []
        for await event in await loop.run(sessionId: sid, userText: "¿seguimos?") { events.append(event) }
        #expect(events.contains(.contextTrimmed(model: "Modelo local (Apple)")))
        #expect(!events.contains { if case .error = $0 { return true } else { return false } })
        #expect(events.contains { if case .context(let g) = $0 { return g.budgetTokens == 4096 } else { return false } })
        let sent = try #require(provider.captures.value.first?.messages)
        #expect(LocalRelief.estimateTokens(sent) < 4096)
        #expect(sent.last == .user("¿seguimos?"))
        let boundary = try #require(try store.currentBoundary(sessionId: sid))
        #expect(boundary.kind == .trim && boundary.model == "Modelo local (Apple)")
        // La ventana siguiente ya arranca en la frontera: no recorta de nuevo.
        let window = try store.window(sessionId: sid)
        #expect(window.first == .user("¿seguimos?") || window.count <= 4)
        let gauge = try #require(await loop.contextGauge(sessionId: sid))
        #expect(gauge.model == "Modelo local (Apple)" && gauge.percent < 100)
        // El transcript completo sigue ahí (la noche lo ve).
        #expect(try store.visibleTurns(sessionId: sid).count == 23)
    }

    @Test func compactSummarizesAndOpensTheWindowWithTheSummary() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let sid = try Self.longSession(store)
        let provider = CapturingProvider(Array(repeating: [ProviderEvent].text("- hablamos de planes"), count: 12))
        let compactor = ConversationCompactor(selector: try Self.localSelector(provider), store: store,
                                              telemetry: Telemetry(queue: queue))
        #expect(try await compactor.compact(sessionId: sid) == .compacted(summary: "- hablamos de planes"))
        #expect(provider.captures.value.count >= 2)   // local: por trozos ≤ 2k tokens + el resumen final
        let window = try store.window(sessionId: sid)
        #expect(window == [.user(ContextBoundary.summaryHeader + "\n- hablamos de planes")])
        try store.append(sessionId: sid, message: .user("¿y ahora?"))
        #expect(try store.window(sessionId: sid).count == 2)
        let empty = try store.startSession()
        #expect(try await compactor.compact(sessionId: empty) == .nothingToDo)
    }

    @Test func compactFallsBackToTrimWhenTheModelFails() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let sid = try Self.longSession(store)
        let compactor = ConversationCompactor(
            selector: try Self.localSelector(FailingProvider(error: ClassifiedError.contextOverflow)), store: store)
        #expect(try await compactor.compact(sessionId: sid) == .trimmed)
        #expect(try store.window(sessionId: sid).count == ConversationCompactor.fallbackKeepTurns)
        #expect(ConversationCompactor.chunks("a\n\nb", size: 10) == ["a\n\nb"])
        #expect(ConversationCompactor.chunks(String(repeating: "x", count: 25), size: 10).count == 1)
        #expect(ConversationCompactor.chunks("aaaaaa\n\nbbbbbb", size: 8) == ["aaaaaa", "bbbbbb"])
    }

    @Test func newConversationKeepsMemoryAndStartsClean() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let brain = Brain(queue: queue)
        _ = try await brain.add(MemoryCandidate(content: "Le gusta correr temprano"))
        let sid = try Self.longSession(store)
        let fresh = try store.beginNewConversation(after: sid)
        #expect(fresh != sid)
        #expect(try store.window(sessionId: fresh).isEmpty)
        #expect(try store.session(sid)?.cleanShutdown == true)
        #expect(try await brain.browse().count == 1)
        #expect(try store.visibleTurns(sessionId: sid).count == 20)
    }

    @MainActor
    @Test func retryAfterContextExceededTrimsFirstAndHistoryShowsDividers() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let sid = try Self.longSession(store)
        let loop = AgentLoop(selector: try Self.localSelector(FailingProvider(error: ClassifiedError.contextOverflow)),
                             store: store, telemetry: Telemetry(queue: queue), clientTools: [], sleep: { _ in })
        let chat = ChatViewModel(loop: loop, sessionId: sid)
        chat.input = "hola"
        await chat.send()
        #expect(chat.messages.last?.text == AgentLoop.contextExceededMessage)
        let before = try store.boundaries(sessionId: sid).count
        await chat.retry()
        #expect(try store.boundaries(sessionId: sid).count > before)
        #expect(chat.messages.contains { $0.isSessionDivider && $0.text.hasPrefix("Recorté la conversación") })

        let turns = try store.visibleTurns(sessionId: sid)
        let history = ChatViewModel.history(current: turns, boundaries: try store.boundaries(sessionId: sid))
        #expect(history.contains { $0.isSessionDivider && $0.text == "Recorté la conversación para caber en Modelo local (Apple)" })
        #expect(ContextBoundary(kind: .compaction, fromSeq: 0, createdAt: Date()).dividerText == "Conversación compactada")
        #expect(ContextBoundary(kind: .trim, fromSeq: 0, createdAt: Date()).dividerText.hasSuffix("el modelo"))
        chat.markNewConversation()
        #expect(chat.messages.map(\.text) == [ChatViewModel.newConversationText])
    }

    @MainActor
    @Test func compactFromTheChatAddsTheDivider() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let sid = try Self.longSession(store)
        let provider = CapturingProvider(Array(repeating: [ProviderEvent].text("- resumen"), count: 12))
        let selector = try Self.localSelector(provider)
        let loop = AgentLoop(selector: selector, store: store, telemetry: Telemetry(queue: queue), clientTools: [],
                             sleep: { _ in })
        let chat = ChatViewModel(loop: loop, sessionId: sid)
        await chat.compact()
        #expect(chat.messages.isEmpty)                                  // sin compactor cableado: nada
        chat.compactor = ConversationCompactor(selector: selector, store: store)
        await chat.compact()
        #expect(chat.messages.last?.text == "Conversación compactada")
        #expect(chat.contextGauge != nil)
    }
}

/// Las 10 tools client-side que el shell registra (App/AnimaApp.swift).
enum RealToolSet {
    static func specs() throws -> [ToolSpec] {
        let w = try ProactiveFixtures.world()
        let tools: [any SensorimotorTool] = [
            CalendarTool(), RemindersTool(), NotesTool(root: FileManager.default.temporaryDirectory),
            PhoneContextTool(), CameraTool(), AudioTool(), GlassesShowTool(host: nil), GlassesCameraTool(host: nil),
            AnimaRemindersTool(store: w.reminders), GoalsTool(otherModel: w.other),
        ]
        return tools.map(\.spec)
    }

    /// `SystemLanguageModel.tokenCount(for: [Tool])` cuando el SDK/OS lo tienen
    /// (macOS 26.4+); nil si no se puede medir aquí.
    static func frameworkTokenCount(_ specs: [ToolSpec]) async -> Int? {
        #if canImport(FoundationModels)
        if #available(macOS 26.4, iOS 26.4, *) {
            let tools: [InterceptingTool] = specs.compactMap { spec in
                guard case .client(let name, let description, let schema) = spec,
                      let generation = try? OnDeviceSchemaBridge.generationSchema(
                        for: OnDeviceSchema.from(jsonSchema: schema, name: name)) else { return nil }
                return InterceptingTool(name: name, description: description, parameters: generation)
            }
            return try? await SystemLanguageModel.default.tokenCount(for: tools)
        }
        #endif
        return nil
    }
}
