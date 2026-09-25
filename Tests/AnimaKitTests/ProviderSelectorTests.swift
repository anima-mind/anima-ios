import Foundation
import Testing
@testable import AnimaKit

@Suite struct ProviderSelectorTests {

    private func selector(_ mode: OperatingMode,
                          availability: @escaping @Sendable () -> OnDeviceAvailability = { .available },
                          claudeProvider: Provider = MockProvider(events: .text("claude")),
                          localProvider: Provider = MockProvider(events: .text("local")),
                          withClaude: Bool = true) throws -> ProviderSelector {
        let claude = withClaude
            ? ProviderSelector.RemoteCortex(provider: claudeProvider, router: try .haikuAll(),
                                            authMode: .apiKey, token: "sk-ant-api03-xyz")
            : nil
        let local = ProviderSelector.LocalCortex(provider: localProvider, router: try OnDeviceTestConfig.router())
        return ProviderSelector(mode: mode, remote: claude, local: local, availability: availability)
    }

    // MARK: los 3 modos × 7 TurnClasses

    @Test func onDeviceOnlyRoutesEveryClassLocally() throws {
        let s = try selector(.onDeviceOnly)
        for turn in TurnClass.allCases {
            #expect(s.backend(for: turn) == .onDevice)
            let binding = try #require(s.binding(for: turn))
            #expect(binding.router.route(turn).model == OnDeviceProvider.modelName)
            #expect(binding.token.isEmpty)   // sin auth en local
        }
    }

    @Test func claudeRoutesEveryClassToClaude() throws {
        let s = try selector(.remote)
        for turn in TurnClass.allCases {
            #expect(s.backend(for: turn) == .remote)
            let binding = try #require(s.binding(for: turn))
            #expect(binding.router.route(turn).model.hasPrefix("claude-"))
            #expect(binding.token == "sk-ant-api03-xyz")
        }
    }

    @Test func hybridSplitsConversationAndSleep() throws {
        let s = try selector(.hybrid)
        let expected: [TurnClass: ProviderBackend] = [
            .interactive: .remote, .interactiveHard: .remote, .restructure: .remote,
            .consolidation: .onDevice, .reconsolidation: .onDevice, .desirePulse: .onDevice, .distill: .onDevice,
        ]
        #expect(Set(expected.keys) == Set(TurnClass.allCases))
        for (turn, backend) in expected {
            #expect(s.backend(for: turn) == backend, "\(turn)")
            #expect(ProviderSelector.plannedBackend(mode: .hybrid, turn: turn) == backend)
        }
    }

    // MARK: disponibilidad y caída

    @Test func hybridFallsBackToClaudeWhenLocalUnavailable() throws {
        let s = try selector(.hybrid, availability: { .modelNotReady })
        for turn in TurnClass.allCases {
            #expect(s.backend(for: turn) == .remote)
        }
        #expect(s.sleepRequiresNetwork)
    }

    /// Solo teléfono jamás cae a Claude: sin modelo local el turno falla con el porqué.
    @Test func onDeviceOnlyNeverFallsBackToClaude() throws {
        let s = try selector(.onDeviceOnly, availability: { .appleIntelligenceOff })
        #expect(s.backend(for: .interactive) == .onDevice)
        #expect(s.backend(for: .consolidation) == .onDevice)
    }

    @Test func claudeModeWithoutTokenHasNoBinding() throws {
        let s = try selector(.remote, withClaude: false)
        #expect(s.binding(for: .interactive) == nil)
    }

    /// La availability cae A MITAD (entre el check del selector y la llamada):
    /// el FallbackProvider repite en Claude con la ruta de Claude.
    @Test func hybridFallsBackMidCallWhenModelDisappears() async throws {
        let flips = Locked(0)
        // 1ª lectura (selector): disponible. 2ª (dentro del provider): no.
        let availability: @Sendable () -> OnDeviceAvailability = {
            flips.mutate { n -> OnDeviceAvailability in n += 1; return n == 1 ? .available : .modelNotReady }
        }
        let local = OnDeviceProvider(session: MockOnDeviceSession([[.snapshot("local")]]), availability: availability)
        let claude = CapturingProvider([.text("desde claude")])
        let s = try selector(.hybrid, availability: availability, claudeProvider: claude, localProvider: local)

        let binding = try #require(s.binding(for: .consolidation))
        #expect(binding.backend == .onDevice)
        let response = try await binding.provider.completeCollecting(
            AssembledContext(messages: [.user("destila")]), tools: [],
            opts: binding.callOpts(route: binding.router.route(.consolidation), systemPromptBase: "tarea"))
        #expect(response.content == [.text("desde claude")])
        #expect(claude.captures.value.first?.route.model == "claude-haiku-4-5")
    }

    @Test func sleepRunsOfflineWhenLocal() throws {
        #expect(try selector(.hybrid).sleepRequiresNetwork == false)
        #expect(try selector(.onDeviceOnly).sleepRequiresNetwork == false)
        #expect(try selector(.remote).sleepRequiresNetwork == true)
        #expect(SleepScheduler(selector: try selector(.hybrid)).requiresNetworkConnectivity == false)
    }

    @Test func conversationProfileFollowsInteractiveBackend() throws {
        #expect(try selector(.onDeviceOnly).conversationProfile == .onDevice)
        #expect(try selector(.hybrid).conversationProfile == .claude)
        #expect(try selector(.remote).conversationProfile == .claude)
    }

    // MARK: persistencia del modo

    @Test func modeStorePersistsAndDefaultsToClaude() throws {
        let suite = "test.anima.mode.\(UUID().uuidString)"
        let ud = try #require(UserDefaults(suiteName: suite))
        defer { ud.removePersistentDomain(forName: suite) }
        let store = OperatingModeStore(defaults: ud)
        #expect(store.storedMode == nil)
        #expect(store.mode == .remote)   // instalaciones previas a §4.9
        store.set(.onDeviceOnly)
        #expect(OperatingModeStore(defaults: ud).mode == .onDeviceOnly)
    }

    // MARK: consumidores

    /// El sueño en Híbrido corre en el modelo local y cuesta $0 en telemetría.
    @Test func consolidatorInHybridUsesLocalCortexAtZeroCost() async throws {
        let queue = try AnimaDatabase.temporary()
        let telemetry = Telemetry(queue: queue)
        let local = CapturingProvider(Array(repeating: [ProviderEvent].text("[]"), count: 20))
        let claude = CapturingProvider([])
        let s = try selector(.hybrid, claudeProvider: claude, localProvider: local)
        let brain = Brain(queue: queue)
        let inbox = ConsolidationInbox(queue: queue)
        try inbox.enqueue(sessionId: nil, text: "me mudé a Medellín")
        let consolidator = Consolidator(brain: brain, queue: queue, selector: s, telemetry: telemetry)
        _ = try await consolidator.cycle()

        #expect(!local.captures.value.isEmpty)
        #expect(claude.captures.value.isEmpty)
        #expect(local.captures.value.allSatisfy { $0.route.model == OnDeviceProvider.modelName })
        #expect(try telemetry.totalCostUSD() == 0)
    }

    /// Solo teléfono: la conversación entera corre local, sin server tools.
    @Test func agentLoopInOnDeviceOnlyTalksLocally() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let sid = try store.startSession()
        let session = MockOnDeviceSession([[.snapshot("Hola"), .snapshot("Hola, aquí estoy.")]])
        let local = OnDeviceProvider(session: session, availability: { .available })
        let s = ProviderSelector(mode: .onDeviceOnly, remote: nil,
                                 local: .init(provider: local, router: try OnDeviceTestConfig.router()),
                                 availability: { .available })
        let loop = AgentLoop(selector: s, store: store, telemetry: Telemetry(queue: queue),
                             clientTools: [CalendarTool()], serverTools: [WebSearchTool.spec], sleep: { _ in })
        var text = ""
        var finished = false
        for await event in await loop.run(sessionId: sid, userText: "hola") {
            if case .textDelta(let d) = event { text += d }
            if case .turnFinished(.endTurn) = event { finished = true }
        }
        #expect(finished)
        #expect(text == "Hola, aquí estoy.")
        let request = try #require(session.requests.value.first)
        #expect(request.tools.map(\.name) == ["calendar"])   // web_search fuera
        #expect(request.instructions.hasPrefix(OnDeviceTestConfig.prompt))
    }
}

#if canImport(SwiftUI)
/// Ajustes › Modo: cambiar entre los 3 sin re-onboarding.
@MainActor
@Suite struct SettingsModeTests {
    private func makeModel(availability: OnDeviceAvailability) throws -> (SettingsViewModel, UserDefaults, String) {
        let suite = "test.anima.settings.\(UUID().uuidString)"
        let ud = try #require(UserDefaults(suiteName: suite))
        let model = SettingsViewModel(
            keychain: ProviderTokenStore(service: "test.anima.settings.\(UUID().uuidString)"),
            telemetry: Telemetry(queue: try AnimaDatabase.temporary()),
            onboardingDefaults: OnboardingDefaults(defaults: ud),
            availability: { availability })
        return (model, ud, suite)
    }

    @Test func switchesToOnDeviceWithoutTokenAndNotifiesShell() throws {
        let (model, ud, suite) = try makeModel(availability: .available)
        defer { ud.removePersistentDomain(forName: suite) }
        model.load()
        var changed: OperatingMode?
        model.onModeChanged = { changed = $0 }
        model.select(.onDeviceOnly)
        #expect(model.mode == .onDeviceOnly)
        #expect(changed == .onDeviceOnly)
        #expect(OperatingModeStore(defaults: ud).mode == .onDeviceOnly)
        // Claude/Híbrido sin token: bloqueados con el porqué.
        #expect(model.blocker(for: .remote) != nil)
        model.select(.hybrid)
        #expect(model.mode == .onDeviceOnly)
        #expect(model.modeNotice != nil)
    }

    @Test func unavailableLocalModelBlocksLocalModesWithReason() throws {
        let (model, ud, suite) = try makeModel(availability: .appleIntelligenceOff)
        defer { ud.removePersistentDomain(forName: suite) }
        model.load()
        #expect(model.blocker(for: .onDeviceOnly) == OnDeviceAvailability.appleIntelligenceOff.reason)
        model.select(.onDeviceOnly)
        #expect(model.mode == .remote)
    }

    @Test func placementShowsWhatRunsWhere() {
        let hybrid = SettingsViewModel.placement(for: .hybrid).map(\.backend)
        #expect(hybrid == [.remote, .onDevice])
        #expect(SettingsViewModel.placement(for: .onDeviceOnly).map(\.backend) == [.onDevice, .onDevice])
        #expect(SettingsViewModel.placement(for: .remote).map(\.backend) == [.remote, .remote])
    }
}
#endif
