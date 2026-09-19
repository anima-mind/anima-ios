import Foundation
import Testing
@testable import AnimaKit

// MARK: - Provider mock (sin red)

/// Provider que reproduce una secuencia fija de eventos.
struct MockProvider: Provider {
    let events: [ProviderEvent]
    func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Provider con guion por llamada: la n-ésima invocación reproduce el n-ésimo script.
final class ScriptedProvider: Provider, @unchecked Sendable {
    private let scripts: [[ProviderEvent]]
    private let index = Locked(0)
    init(_ scripts: [[ProviderEvent]]) { self.scripts = scripts }

    func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        let i = index.mutate { current -> Int in let c = current; current += 1; return c }
        let events = i < scripts.count ? scripts[i] : []
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Provider con guion por llamada que además CAPTURA los messages ensamblados y
/// la ruta (modelo/effort) de cada invocación — para asserts sobre inyección de
/// system messages y ruteo por TurnClass (Fase 3).
final class CapturingProvider: Provider, @unchecked Sendable {
    struct Capture: Sendable { let messages: [Message]; let route: ModelRoute }
    private let scripts: [[ProviderEvent]]
    private let index = Locked(0)
    let captures = Locked<[Capture]>([])

    init(_ scripts: [[ProviderEvent]]) { self.scripts = scripts }

    func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        let i = index.mutate { current -> Int in let c = current; current += 1; return c }
        captures.mutate { $0.append(Capture(messages: ctx.messages, route: opts.route)) }
        let events = i < scripts.count ? scripts[i] : []
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

// MARK: - Config de Anthropic para tests (mismo JSON de consola que RemoteConfigTests)

enum TestConfig {
    static let consoleJSON = Data("""
    {
      "anthropic": {
        "api": {
          "base_url": "https://api.anthropic.com",
          "version": "2023-06-01",
          "betas": ["compact-2026-01-12", "context-management-2025-06-27", "interleaved-thinking-2025-05-14"],
          "auth_betas": { "oauth": ["oauth-2025-04-20", "claude-code-20250219"] },
          "auth_system_prefix": { "oauth": "You are Claude Code, Anthropic's official CLI for Claude." }
        },
        "routes": {
          "interactive":     { "model": "claude-opus-4-8",  "effort": "medium", "max_tokens": 16000 },
          "interactiveHard": { "model": "claude-opus-4-8",  "effort": "high",   "max_tokens": 32000 },
          "restructure":     { "model": "claude-opus-4-8",  "effort": "high",   "max_tokens": 32000 },
          "consolidation":   { "model": "claude-haiku-4-5", "max_tokens": 4000 }
        }
      }
    }
    """.utf8)

    static func providerConfig(base: String = "Eres Anima, un asistente personal.") throws -> ProviderConfig {
        let parsed = try ProviderConfigParser.parse(consoleJSON)
        let entry = try #require(parsed[.anthropic])
        return ProviderConfig(systemPromptBase: base, api: entry.api, routes: entry.routes)
    }

    static func callOpts(authMode: AuthMode, base: String = "Eres Anima.",
                         enableThinking: Bool = true) throws -> CallOpts {
        let config = try providerConfig(base: base)
        return CallOpts(
            route: config.routes[.interactive]!,
            api: config.api,
            authMode: authMode,
            token: authMode == .oauth ? "sk-ant-oat01-xyz" : "sk-ant-api03-xyz",
            systemPromptBase: base,
            enableThinking: enableThinking)
    }
}

// MARK: - Helpers de eventos y router para el Consolidator (Fase 2)

extension Array where Element == ProviderEvent {
    /// Un turno de solo texto (respuesta del Consolidator vía Haiku mockeado).
    static func text(_ s: String) -> [ProviderEvent] {
        [.messageStart(id: "m", model: "claude-haiku-4-5"),
         .textDelta(s),
         .messageDelta(stopReason: .endTurn, usage: Usage()),
         .messageStop]
    }
}

extension ModelRouter {
    /// Router que rutea TODA clase de turno a Haiku (para tests del ciclo).
    static func haikuAll(base: String = "system") throws -> ModelRouter {
        let api = try TestConfig.providerConfig().api
        let haiku = ModelRoute(model: "claude-haiku-4-5", effort: nil, maxTokens: 4000)
        var routes: [TurnClass: ModelRoute] = [:]
        for turn in TurnClass.allCases { routes[turn] = haiku }
        return ModelRouter(config: ProviderConfig(systemPromptBase: base, api: api, routes: routes))
    }
}

// MARK: - Walk de JSONValue (para asserts sobre el body del request)

extension JSONValue {
    /// Todas las claves de objeto presentes en el árbol (recursivo).
    func allObjectKeys() -> Set<String> {
        var keys: Set<String> = []
        switch self {
        case .object(let o):
            for (k, v) in o { keys.insert(k); keys.formUnion(v.allObjectKeys()) }
        case .array(let a):
            for v in a { keys.formUnion(v.allObjectKeys()) }
        default:
            break
        }
        return keys
    }

    /// Navega una ruta de claves de objeto.
    func at(_ path: String...) -> JSONValue? {
        var current: JSONValue? = self
        for key in path { current = current?[key] }
        return current
    }
}
