// ModelRouter.swift — el dial de portabilidad (§4.7): TurnClass → ModelRoute,
// leído del ConfigSnapshot (config remota). Fase 0 solo ejercita `.interactive`,
// pero la interfaz cubre todas las clases de turno.

import Foundation

public struct ModelRouter: Sendable {
    private let config: ProviderConfig

    public init(config: ProviderConfig) {
        self.config = config
    }

    /// Ruta para un tipo de turno. Si la config no define la clase, cae a
    /// `.interactive` y, en último caso, a un default de Opus 4.8 medium.
    public func route(_ turn: TurnClass) -> ModelRoute {
        if let r = config.routes[turn] { return r }
        if let r = config.routes[.interactive] { return r }
        return ModelRoute(model: "claude-opus-4-8", effort: "medium", maxTokens: 16_000)
    }

    public var systemPromptBase: String { config.systemPromptBase }
    public var api: ProviderAPIConfig { config.api }
}

/// Qué parámetros acepta cada modelo (§4.2, regla dura 1). Para Opus 4.8/4.7 y
/// Haiku 4.5: PROHIBIDO temperature/top_p/top_k/thinking.budget_tokens (→ 400).
/// El único knob de profundidad es output_config.effort, y solo en modelos que
/// lo soportan (Haiku 4.5 NO lo soporta).
public struct ModelParamPolicy: Sendable {
    public let allowsEffort: Bool
    public let allowsThinking: Bool

    public static func policy(for model: String) -> ModelParamPolicy {
        if model.hasPrefix("claude-haiku") {
            // Haiku 4.5 no acepta effort; el thinking de los ciclos va deshabilitado.
            return ModelParamPolicy(allowsEffort: false, allowsThinking: false)
        }
        // Opus 4.x / Sonnet: adaptive + effort.
        return ModelParamPolicy(allowsEffort: true, allowsThinking: true)
    }
}
