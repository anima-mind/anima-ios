import Foundation
import Testing
@testable import AnimaKit

/// Valida que el JSON EXACTO que se pega en la consola de Firebase
/// (parámetro `provider_config`) parsea correcto — si este test pasa,
/// la consola y la app hablan el mismo idioma.
@Suite struct RemoteConfigTests {

    static let consoleJSON = Data("""
    {
      "anthropic": {
        "api": {
          "base_url": "https://api.anthropic.com",
          "version": "2023-06-01",
          "betas": ["compact-2026-01-12", "context-management-2025-06-27", "interleaved-thinking-2025-05-14", "prompt-caching-scope-2026-01-05", "extended-cache-ttl-2025-04-11"],
          "auth_betas": { "oauth": ["oauth-2025-04-20", "claude-code-20250219"], "modo_futuro": ["x"] },
          "auth_system_prefix": { "oauth": "You are Claude Code, Anthropic's official CLI for Claude.", "modo_futuro": "x" }
        },
        "routes": {
          "interactive":     { "model": "claude-opus-4-8",  "effort": "medium", "max_tokens": 16000 },
          "interactiveHard": { "model": "claude-opus-4-8",  "effort": "high",   "max_tokens": 32000 },
          "consolidation":   { "model": "claude-haiku-4-5", "max_tokens": 4000 }
        }
      },
      "openai": {
        "api": { "base_url": "https://api.openai.com" },
        "routes": { "interactive": { "model": "gpt-5", "max_tokens": 16000 } }
      },
      "provider_del_futuro": {
        "api": { "base_url": "https://example.com" },
        "routes": { "turno_del_futuro": { "model": "x", "max_tokens": 1 } }
      }
    }
    """.utf8)

    @Test func parsesConsoleJSON() throws {
        let parsed = try ProviderConfigParser.parse(Self.consoleJSON)

        let anthropic = try #require(parsed[.anthropic])
        #expect(anthropic.api.version == "2023-06-01")
        #expect(!anthropic.api.betas.contains("oauth-2025-04-20"))  // NO va en las comunes
        #expect(anthropic.routes[.interactive]?.model == "claude-opus-4-8")
        #expect(anthropic.routes[.interactive]?.effort == "medium")
        #expect(anthropic.routes[.consolidation]?.model == "claude-haiku-4-5")
        #expect(anthropic.routes[.consolidation]?.effort == nil)

        let openai = try #require(parsed[.openai])
        #expect(openai.api.version == nil)
        #expect(openai.api.betas.isEmpty)
    }

    @Test func authModeBetas() throws {
        let parsed = try ProviderConfigParser.parse(Self.consoleJSON)
        let api = try #require(parsed[.anthropic]).api
        // oauth suma su beta obligatoria; api_key jamás la lleva
        #expect(api.effectiveBetas(for: .oauth).contains("oauth-2025-04-20"))
        #expect(!api.effectiveBetas(for: .apiKey).contains("oauth-2025-04-20"))
        #expect(api.effectiveBetas(for: .oauth).contains("claude-code-20250219"))
        #expect(!api.effectiveBetas(for: .apiKey).contains("claude-code-20250219"))
        #expect(api.effectiveBetas(for: .apiKey).contains("compact-2026-01-12"))
        #expect(api.authBetas.count == 1)  // "modo_futuro" ignorado
    }

    @Test func authModeSystemPrefix() throws {
        let parsed = try ProviderConfigParser.parse(Self.consoleJSON)
        let api = try #require(parsed[.anthropic]).api
        // oauth: el array system abre con el bloque de Claude Code y luego el base
        #expect(api.systemBlocks(for: .oauth, base: "anima-base") ==
                ["You are Claude Code, Anthropic's official CLI for Claude.", "anima-base"])
        // api_key: solo el base, sin prefijo
        #expect(api.systemBlocks(for: .apiKey, base: "anima-base") == ["anima-base"])
        #expect(api.authSystemPrefixes.count == 1)  // "modo_futuro" ignorado
    }

    @Test func authModeDetectionFromToken() {
        #expect(AuthMode.detect(fromToken: "sk-ant-oat01-abc") == .oauth)
        #expect(AuthMode.detect(fromToken: "sk-ant-api03-abc") == .apiKey)
        #expect(AuthMode.detect(fromToken: "algo-raro") == nil)
    }

    @Test func unknownKeysAreIgnoredNotFatal() throws {
        // Un provider o turn class agregado en la consola el año que viene
        // no puede crashear la app de hoy.
        let parsed = try ProviderConfigParser.parse(Self.consoleJSON)
        #expect(parsed.count == 2)  // provider_del_futuro ignorado
        let anthropic = try #require(parsed[.anthropic])
        #expect(anthropic.routes.count == 3)
    }

    @Test func promptKeysPerProvider() {
        #expect(ProviderConfigParser.promptKey(for: .anthropic) == "system_prompt_anthropic")
        #expect(ProviderConfigParser.promptKey(for: .onDevice) == "system_prompt_on_device")
    }

    @Test func snapshotLookup() {
        let api = ProviderAPIConfig(baseURL: URL(string: "https://api.anthropic.com")!,
                                    version: "2023-06-01", betas: [])
        let cfg = ProviderConfig(systemPromptBase: "base", api: api, routes: [:])
        let snap = ConfigSnapshot(providers: [.anthropic: cfg])
        #expect(snap.config(for: .anthropic)?.systemPromptBase == "base")
        #expect(snap.config(for: .google) == nil)
        #expect(StaticConfigProvider(snap).snapshot() == snap)
    }

    /// Los defaults bundled (sin red, primera apertura) traen la entrada
    /// on_device idéntica a la publicada: 7 rutas al modelo local y su prompt.
    @Test func bundledDefaultsIncludeOnDeviceEntry() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/RemoteConfigDefaults.plist")
        let dict = try #require(NSDictionary(contentsOf: plist) as? [String: String])
        let parsed = try ProviderConfigParser.parse(Data(try #require(dict["provider_config"]).utf8))
        let onDevice = try #require(parsed[.onDevice])
        #expect(onDevice.api.baseURL.absoluteString == "local://device")
        #expect(onDevice.api.betas.isEmpty)
        #expect(Set(onDevice.routes.keys) == Set(TurnClass.allCases))
        #expect(onDevice.routes.values.allSatisfy { $0.model == OnDeviceProvider.modelName })
        #expect(dict[ProviderConfigParser.promptKey(for: .onDevice)]?.isEmpty == false)
        #expect(parsed[.anthropic] != nil)
    }
}
