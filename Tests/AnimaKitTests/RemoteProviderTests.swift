import Foundation
import Testing
@testable import AnimaKit

// MARK: - Provider remoto: helpers, persistencia y fábrica

@Suite struct RemoteProviderTests {

    private func defaults() throws -> (UserDefaults, String) {
        let suite = "test.anima.remote.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func compatConfig(_ kind: ModelProvider) -> ProviderConfig {
        let base = kind == .google ? CompatTestConfig.googleBase : CompatTestConfig.openAIBase
        return ProviderConfig(systemPromptBase: "B", api: ProviderAPIConfig(baseURL: base, version: nil, betas: []),
                              routes: [.interactive: ModelRoute(model: "gpt-5.2", effort: nil, maxTokens: 100)])
    }

    @Test func modelProviderHelpers() {
        #expect(ModelProvider.remoteCases == [.anthropic, .openai, .google])
        #expect(ModelProvider.remoteCases.allSatisfy { $0.isRemote })
        #expect(!ModelProvider.onDevice.isRemote)
        #expect(ModelProvider.openai.usesOpenAICompatWire && ModelProvider.google.usesOpenAICompatWire)
        #expect(!ModelProvider.anthropic.usesOpenAICompatWire)
        #expect(ModelProvider.allCases.map(\.displayName) == ["Claude", "OpenAI", "Gemini", "este teléfono"])
        #expect(ModelProvider.allCases.map(\.tokenPlaceholder) == ["sk-ant-…", "sk-…", "AIza…", ""])

        #expect(ModelProvider.hint(fromToken: " sk-ant-api03-x ") == .anthropic)
        #expect(ModelProvider.hint(fromToken: "sk-proj-abc") == .openai)
        #expect(ModelProvider.hint(fromToken: "AIzaSyXYZ") == .google)
        #expect(ModelProvider.hint(fromToken: "otra-cosa") == nil)

        #expect(ModelProvider.anthropic.acceptsTokenFormat("sk-ant-oat01-x"))
        #expect(!ModelProvider.anthropic.acceptsTokenFormat("sk-proj-x"))
        #expect(ModelProvider.openai.acceptsTokenFormat("cualquier-formato"))   // hint, no gate
        #expect(!ModelProvider.google.acceptsTokenFormat("con espacio"))
        #expect(!ModelProvider.google.acceptsTokenFormat("  "))
        #expect(!ModelProvider.onDevice.acceptsTokenFormat("x"))

        #expect(ModelProvider.anthropic.authMode(forToken: "sk-ant-oat01-x") == .oauth)
        #expect(ModelProvider.openai.authMode(forToken: "sk-x") == .apiKey)
        #expect(ModelProvider.google.authMode(forToken: "") == nil)
        #expect(ModelProvider.onDevice.authMode(forToken: "x") == nil)
    }

    @Test func remoteStoreDefaultsToAnthropicAndIgnoresNonRemote() throws {
        let (ud, suite) = try defaults()
        defer { ud.removePersistentDomain(forName: suite) }
        let store = RemoteProviderStore(defaults: ud)
        #expect(store.storedProvider == nil)
        #expect(store.provider == .anthropic)
        store.set(.google)
        #expect(RemoteProviderStore(defaults: ud).provider == .google)
        store.set(.onDevice)   // no es remoto: ignorado
        #expect(store.provider == .google)
        ud.set("on_device", forKey: RemoteProviderStore.key)
        #expect(store.storedProvider == nil)
        ud.set("basura", forKey: RemoteProviderStore.key)
        #expect(store.provider == .anthropic)
    }

    /// Los UserDefaults persistidos antes del cambio ("claude") siguen leyendo remoto.
    @Test func legacyPersistedModeStillReadsAsRemote() throws {
        let (ud, suite) = try defaults()
        defer { ud.removePersistentDomain(forName: suite) }
        ud.set("claude", forKey: OperatingModeStore.key)
        #expect(OperatingModeStore(defaults: ud).storedMode == .remote)
        OperatingModeStore(defaults: ud).set(.remote)
        #expect(ud.string(forKey: OperatingModeStore.key) == "claude")
    }

    @Test func modeTitlesNameTheActiveRemote() {
        #expect(OperatingMode.remote.title == "Claude")
        #expect(OperatingMode.remote.title(remote: .openai) == "OpenAI")
        #expect(OperatingMode.remote.summary(remote: .google).contains("Gemini"))
        #expect(OperatingMode.hybrid.summary(remote: .openai).contains("OpenAI"))
        #expect(OperatingMode.hybrid.title(remote: .google) == "Híbrido")
        #expect(OperatingMode.onDeviceOnly.summary(remote: .openai).contains("Apple"))
        #expect(ProviderBackend.remote.label == "Claude")
        #expect(ProviderBackend.remote.label(remote: .google) == "Gemini")
        #expect(ProviderBackend.onDevice.label(remote: .openai) == "este teléfono")
    }

    @Test func factoryBuildsTheRightProvider() throws {
        let anthropic = try TestConfig.providerConfig()
        let claude = try #require(RemoteCortexFactory.make(kind: .anthropic, config: anthropic, token: "sk-ant-oat01-x"))
        #expect(claude.provider is ClaudeProvider)
        #expect(claude.authMode == .oauth)
        #expect(claude.kind == .anthropic)

        let openai = try #require(RemoteCortexFactory.make(kind: .openai, config: compatConfig(.openai), token: "sk-proj-x"))
        #expect(openai.provider is OpenAICompatProvider)
        #expect(openai.kind == .openai)
        #expect(openai.router.api.baseURL == CompatTestConfig.openAIBase)

        let google = try #require(RemoteCortexFactory.make(kind: .google, config: compatConfig(.google), token: "AIza-x"))
        #expect(google.provider is OpenAICompatProvider)

        #expect(RemoteCortexFactory.make(kind: .anthropic, config: anthropic, token: "sk-proj-x") == nil)
        #expect(RemoteCortexFactory.make(kind: .openai, config: nil, token: "sk-x") == nil)
        #expect(RemoteCortexFactory.make(kind: .openai, config: compatConfig(.openai), token: "") == nil)
        #expect(RemoteCortexFactory.make(kind: .onDevice, config: anthropic, token: "x") == nil)
    }

    @Test func selectorWithCompatRemote() throws {
        let remote = try #require(RemoteCortexFactory.make(kind: .google, config: compatConfig(.google), token: "AIza-x"))
        let local = ProviderSelector.LocalCortex(provider: MockProvider(events: .text("local")),
                                                 router: try OnDeviceTestConfig.router())
        let s = ProviderSelector(mode: .hybrid, remote: remote, local: local, availability: { .available })
        #expect(s.remoteKind == .google)
        #expect(s.modeTitle == "Híbrido")
        #expect(s.conversationProfile == .openAICompat)
        #expect(s.binding(for: .interactive)?.kind == .google)
        #expect(s.binding(for: .interactive)?.token == "AIza-x")
        #expect(s.binding(for: .consolidation)?.kind == .onDevice)

        let remoteOnly = ProviderSelector(mode: .remote, remote: remote, local: nil, availability: { .available })
        #expect(remoteOnly.modeTitle == "Gemini")
        #expect(ProviderSelector(mode: .remote, remote: nil, local: nil, availability: { .available }).remoteKind == .anthropic)
    }

    @Test func compatProfileUsesLocalReliefWithoutAnthropicBetas() {
        #expect(ContextProfile.openAICompat.reliefMode == .localMechanical)
        #expect(ContextProfile.openAICompat.contextBudgetTokens == 128_000)
        #expect(ContextProfile.forBackend(.remote, remote: .openai) == .openAICompat)
        #expect(ContextProfile.forBackend(.remote) == .claude)
        #expect(ContextProfile.forBackend(.onDevice, remote: .google) == .onDevice)
    }

    /// El JSON bundled (App/RemoteConfigDefaults.plist) trae openai y google con
    /// sus prompts: la app funciona sin red con cualquiera de los 3 remotos.
    @Test func bundledDefaultsCarryCompatProviders() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/RemoteConfigDefaults.plist")
        let dict = try #require(NSDictionary(contentsOf: plist) as? [String: String])
        let parsed = try ProviderConfigParser.parse(Data(try #require(dict["provider_config"]).utf8))
        let openai = try #require(parsed[.openai])
        let google = try #require(parsed[.google])
        #expect(openai.api.baseURL.absoluteString == "https://api.openai.com/v1")
        #expect(google.api.baseURL.absoluteString == "https://generativelanguage.googleapis.com/v1beta/openai")
        for (entry, big, cheap) in [(openai, "gpt-5.2", "gpt-5-mini"), (google, "gemini-3.1-pro-preview", "gemini-3.8-flash")] {
            #expect(Set(entry.routes.keys) == Set(TurnClass.allCases))
            #expect(entry.routes[.interactive]?.model == big)
            #expect(entry.routes[.consolidation]?.model == cheap)
            #expect(entry.routes.values.allSatisfy { $0.effort == nil } == true)
        }
        for provider in [ModelProvider.openai, .google] {
            #expect(dict[ProviderConfigParser.promptKey(for: provider)]?.isEmpty == false)
        }
    }
}

// MARK: - Keychain: una entrada por provider + migración legacy

@Suite struct ProviderTokenStoreTests {

    @Test func oneEntryPerProvider() throws {
        let backend = InMemoryKeychain()
        let store = ProviderTokenStore(service: "svc", backend: backend)
        try store.save("sk-ant-api03-a", for: .anthropic)
        try store.save("sk-proj-b", for: .openai)
        #expect(try store.read(.anthropic) == "sk-ant-api03-a")
        #expect(try store.read(.openai) == "sk-proj-b")
        #expect(try store.read(.google) == nil)
        #expect(store.hasToken(.openai))
        #expect(!store.hasToken(.google))
        #expect(backend.lastAdd.value?[kSecAttrAccount as String] as? String == "anima.token.openai")
        try store.delete(.openai)
        #expect(!store.hasToken(.openai))
        #expect(ProviderTokenStore.account(for: .google) == "anima.token.google")
    }

    @Test func legacyEntryMigratesAsAnthropicOnRead() throws {
        let backend = InMemoryKeychain()
        try KeychainStore(service: "svc", account: "default", backend: backend).save("sk-ant-oat01-legacy")
        let store = ProviderTokenStore(service: "svc", backend: backend)
        #expect(try store.read(.openai) == nil)                     // la legacy jamás es de otro
        #expect(try store.read(.anthropic) == "sk-ant-oat01-legacy")
        #expect(try KeychainStore(service: "svc", account: "default", backend: backend).read() == nil)
        #expect(try KeychainStore(service: "svc", account: "anima.token.anthropic", backend: backend).read()
                == "sk-ant-oat01-legacy")
        #expect(try store.read(.anthropic) == "sk-ant-oat01-legacy")   // ya migrado
    }

    @Test func newEntryWinsOverLegacy() throws {
        let backend = InMemoryKeychain()
        try KeychainStore(service: "svc", account: "default", backend: backend).save("vieja")
        let store = ProviderTokenStore(service: "svc", backend: backend)
        try store.save("nueva", for: .anthropic)
        #expect(try store.read(.anthropic) == "nueva")
    }
}

// MARK: - Validación de keys compat (GET /models con Bearer)

@Suite struct CompatKeyValidatorTests {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }()

    private func rig(_ steps: [[StubStep]]) -> (String, StubScenario) {
        let token = "sk-proj-\(UUID().uuidString)"
        let scenario = StubScenario(steps)
        StubURLProtocol.registry.mutate { $0[token] = scenario }
        return (token, scenario)
    }

    private let api = ProviderAPIConfig(baseURL: CompatTestConfig.googleBase, version: nil, betas: [])

    @Test func requestShape() {
        let req = APIKeyValidator.compatRequest(token: "AIza-x", api: api)
        #expect(req.httpMethod == "GET")
        #expect(req.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/openai/models")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer AIza-x")
    }

    @Test func verdictsFromTheAPI() async {
        let validator = APIKeyValidator(session: Self.session)
        let (ok, s1) = rig([[.http(status: 200), .body("{}"), .finish]])
        #expect(await validator.validate(token: ok, provider: .google, api: api) == .valid(.apiKey))
        #expect(s1.requests.value.first?.url?.path == "/v1beta/openai/models")

        let (bad, _) = rig([[.http(status: 401), .body("{}"), .finish]])
        if case .rejected = await validator.validate(token: bad, provider: .openai, api: api) {} else {
            Issue.record("401 debería rechazar")
        }
        let (down, _) = rig([[.http(status: 503), .body(""), .finish]])
        #expect(await validator.validate(token: down, provider: .openai, api: api) == .offlineAccepted(.apiKey))
        let (offline, _) = rig([[.fail(.notConnectedToInternet)]])
        #expect(await validator.validate(token: offline, provider: .openai, api: api) == .offlineAccepted(.apiKey))
        let (odd, _) = rig([[.nonHTTP, .body("x"), .finish]])
        #expect(await validator.validate(token: odd, provider: .openai, api: api) == .offlineAccepted(.apiKey))
        #expect(await validator.validate(token: "con espacio", provider: .openai, api: api) == .malformed)
        // Anthropic sigue por su camino (count_tokens): formato inválido → malformed.
        #expect(await validator.validate(token: "sk-proj-x", provider: .anthropic, api: api) == .malformed)
    }
}

#if canImport(SwiftUI)
// MARK: - Onboarding con providers remotos

@MainActor
@Suite struct OnboardingRemoteProviderTests {

    private func makeModel(storedMode: OperatingMode? = nil, storedRemote: ModelProvider? = nil,
                           tokens: [ModelProvider: String] = [:],
                           availability: OnDeviceAvailability = .available)
        throws -> (OnboardingViewModel, UserDefaults, String) {
        let suite = "test.anima.onboarding.remote.\(UUID().uuidString)"
        let ud = try #require(UserDefaults(suiteName: suite))
        if let storedMode { OperatingModeStore(defaults: ud).set(storedMode) }
        if let storedRemote { RemoteProviderStore(defaults: ud).set(storedRemote) }
        let keychain = ProviderTokenStore(service: "svc", backend: InMemoryKeychain())
        for (provider, token) in tokens { try keychain.save(token, for: provider) }
        let model = OnboardingViewModel(keychain: keychain, selfModel: nil,
                                        defaults: OnboardingDefaults(defaults: ud),
                                        availability: { availability }) {}
        return (model, ud, suite)
    }

    private func waitForVerdict(_ model: OnboardingViewModel) async throws {
        for _ in 0..<200 where model.keyStatus == .checking || model.keyStatus == .idle {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test func openAIChoiceGoesThroughKeyStepAndPersistsRemote() async throws {
        let (model, ud, suite) = try makeModel()
        defer { ud.removePersistentDomain(forName: suite) }
        model.advance(); model.skipAccount()
        model.selectProvider(.openai)
        #expect(model.selectedProvider == .openai)
        #expect(model.canLeaveProviderStep)
        model.advance()
        #expect(model.step == .apiKey)

        model.keyInput = "AIzaSyX"
        #expect(model.tokenHint == "Parece una key de Gemini, no de OpenAI.")
        model.keyInput = "sk-proj-abc"
        #expect(model.tokenHint == nil)
        model.validateKey()
        try await waitForVerdict(model)
        #expect(model.keyStatus == .offline(.apiKey))   // sin config de API: formato ok
        #expect(model.offersHybrid)
        model.hybridEnabled = false
        model.advance()
        #expect(OperatingModeStore(defaults: ud).mode == .remote)
        #expect(RemoteProviderStore(defaults: ud).provider == .openai)
    }

    @Test func malformedKeysAreRejectedPerProvider() throws {
        let (model, ud, suite) = try makeModel()
        defer { ud.removePersistentDomain(forName: suite) }
        model.selectProvider(.google)
        model.keyInput = "con espacio"
        model.validateKey()
        #expect(model.keyStatus == .rejected("Formato no reconocido (sin espacios)."))
        model.selectProvider(.anthropic)
        model.keyInput = "sk-proj-x"
        model.validateKey()
        #expect(model.keyStatus == .rejected("Formato no reconocido (esperado sk-ant-api… o sk-ant-oat…)."))
        model.keyInput = ""
        model.validateKey()   // vacío: no-op
    }

    @Test func switchingProviderReadsItsSavedKey() throws {
        let (model, ud, suite) = try makeModel(tokens: [.google: "AIza-saved"])
        defer { ud.removePersistentDomain(forName: suite) }
        #expect(model.keyStatus == .idle)            // anthropic sin key
        model.selectProvider(.google)
        #expect(model.keyStatus == .valid(.apiKey))
        model.selectProvider(.google)                // mismo: no-op
        model.selectProvider(.openai)
        #expect(model.keyStatus == .idle)
        model.selectProvider(.onDevice)
        #expect(model.selectedProvider == .onDevice)
    }

    @Test func replayStartsOnStoredRemote() throws {
        let (hybrid, ud1, s1) = try makeModel(storedMode: .hybrid, storedRemote: .google,
                                              tokens: [.google: "AIza-x"])
        defer { ud1.removePersistentDomain(forName: s1) }
        #expect(hybrid.selectedProvider == .google)
        #expect(hybrid.keyStatus == .valid(.apiKey))
        #expect(hybrid.hybridEnabled)

        let (remote, ud2, s2) = try makeModel(storedMode: .remote, storedRemote: .openai)
        defer { ud2.removePersistentDomain(forName: s2) }
        #expect(remote.selectedProvider == .openai)
        #expect(!remote.hybridEnabled)

        let (legacy, ud3, s3) = try makeModel(tokens: [.anthropic: "sk-ant-api03-x"])
        defer { ud3.removePersistentDomain(forName: s3) }
        #expect(legacy.selectedProvider == .anthropic)
        #expect(legacy.keyStatus == .valid(.apiKey))
    }
}

// MARK: - Ajustes: provider remoto activo

@MainActor
@Suite struct SettingsRemoteProviderTests {

    private func makeModel(tokens: [ModelProvider: String] = [:]) throws
        -> (SettingsViewModel, UserDefaults, String, ProviderTokenStore) {
        let suite = "test.anima.settings.remote.\(UUID().uuidString)"
        let ud = try #require(UserDefaults(suiteName: suite))
        let keychain = ProviderTokenStore(service: "svc", backend: InMemoryKeychain())
        for (provider, token) in tokens { try keychain.save(token, for: provider) }
        let model = SettingsViewModel(keychain: keychain, telemetry: Telemetry(queue: try AnimaDatabase.temporary()),
                                      onboardingDefaults: OnboardingDefaults(defaults: ud),
                                      availability: { .available })
        return (model, ud, suite, keychain)
    }

    @Test func switchRemoteRequiresItsKey() throws {
        let (model, ud, suite, _) = try makeModel(tokens: [.anthropic: "sk-ant-api03-x"])
        defer { ud.removePersistentDomain(forName: suite) }
        model.load()
        #expect(model.remoteProvider == .anthropic)
        #expect(model.hasToken)
        #expect(model.detectedMode == .apiKey)
        #expect(model.savedRemotes == [.anthropic])

        var changes = 0
        model.onModeChanged = { _ in changes += 1 }
        model.selectRemote(.openai)
        #expect(model.remoteProvider == .anthropic)
        #expect(model.modeNotice != nil)
        #expect(model.tokenTarget == .openai)       // el campo apunta a la key que falta

        model.tokenInput = "sk-proj-nueva"
        model.save()
        #expect(model.savedRemotes == [.anthropic, .openai])
        #expect(model.statusText.contains("actívala"))
        #expect(changes == 0)

        model.selectRemote(.openai)
        #expect(model.remoteProvider == .openai)
        #expect(RemoteProviderStore(defaults: ud).provider == .openai)
        #expect(model.modeNotice == nil)
        #expect(model.detectedMode == nil)
        #expect(changes == 1)
        model.selectRemote(.openai)                 // mismo: no re-cablea
        model.selectRemote(.onDevice)               // no remoto: ignorado
        #expect(changes == 1)
    }

    @Test func savingActiveKeyRewiresAndValidatesFormat() throws {
        let (model, ud, suite, keychain) = try makeModel()
        defer { ud.removePersistentDomain(forName: suite) }
        model.load()
        #expect(!model.hasToken)
        #expect(model.blocker(for: .remote) == "Requiere tu API key de Claude (abajo).")
        var changes = 0
        model.onModeChanged = { _ in changes += 1 }
        model.tokenInput = "sk-proj-no-es-anthropic"
        model.save()
        #expect(model.statusText.contains("no reconocido"))
        model.tokenTarget = .google
        model.tokenInput = "con espacio"
        model.save()
        #expect(model.statusText.contains("no reconocida"))
        model.tokenTarget = .anthropic
        model.tokenInput = "sk-ant-oat01-ok"
        model.save()
        #expect(model.hasToken)
        #expect(model.detectedMode == .oauth)
        #expect(changes == 1)
        #expect(try keychain.read(.anthropic) == "sk-ant-oat01-ok")
        model.tokenInput = "   "
        model.save()   // vacío: no-op
        #expect(changes == 1)
    }
}
#endif
