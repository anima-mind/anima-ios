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
          "betas": ["oauth-2025-04-20", "compact-2026-01-12", "context-management-2025-06-27"]
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
        #expect(anthropic.api.betas.contains("oauth-2025-04-20"))
        #expect(anthropic.routes[.interactive]?.model == "claude-opus-4-8")
        #expect(anthropic.routes[.interactive]?.effort == "medium")
        #expect(anthropic.routes[.consolidation]?.model == "claude-haiku-4-5")
        #expect(anthropic.routes[.consolidation]?.effort == nil)

        let openai = try #require(parsed[.openai])
        #expect(openai.api.version == nil)
        #expect(openai.api.betas.isEmpty)
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
}
