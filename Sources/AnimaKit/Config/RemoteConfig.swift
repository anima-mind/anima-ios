// RemoteConfig.swift — contrato de configuración remota (plan doc 04 §4.8).
//
// AnimaKit NO conoce Firebase: el app shell implementa `RemoteConfigProviding`
// con Firebase Remote Config y AnimaKit consume el snapshot. Regla dura:
// el snapshot se congela POR SESIÓN (activar config a mitad de sesión
// invalidaría el prompt cache del prefijo estable).
//
// Layout de parámetros en Remote Config:
//   provider_config            → JSON estructurado por provider (api + routes)
//   system_prompt_anthropic    → texto plano (prompt base de Anima para ese provider)
//   system_prompt_openai       → …uno por provider; editar texto largo como
//   system_prompt_google         parámetro plano evita el infierno de escapes
//   system_prompt_on_device      de meterlo dentro de un JSON en la consola.
//
// Los SECRETOS (API key / OAuth token del usuario) JAMÁS viven aquí:
// Remote Config es legible por cualquier cliente. Secretos → Keychain.

import Foundation

// MARK: - Proveedor de config (lo implementa el app shell con Firebase)

public protocol RemoteConfigProviding: Sendable {
    /// Snapshot congelado en frontera de sesión.
    func snapshot() -> ConfigSnapshot
}

// MARK: - Modelo

/// Providers de LLM soportados (onboarding paso 2 del design system).
/// v1 implementa `anthropic`; el resto quedan configurables desde ya.
public enum ModelProvider: String, Sendable, CaseIterable, Codable {
    case anthropic
    case openai
    case google
    case onDevice = "on_device"
}

/// Modo de autenticación contra Anthropic. Se detecta por el prefijo del
/// token guardado en Keychain: `sk-ant-api03…` → apiKey (Console, pago por
/// token, header x-api-key) · `sk-ant-oat01…` → oauth (suscripción Claude,
/// header Authorization: Bearer + beta oauth-2025-04-20 obligatoria).
public enum AuthMode: String, Sendable, CaseIterable, Codable {
    case apiKey = "api_key"
    case oauth

    public static func detect(fromToken token: String) -> AuthMode? {
        if token.hasPrefix("sk-ant-oat") { return .oauth }
        if token.hasPrefix("sk-ant-api") { return .apiKey }
        return nil
    }
}

/// Clases de turno del dial (plan doc 04 §4.7).
public enum TurnClass: String, Sendable, CaseIterable, Codable {
    case interactive
    case interactiveHard
    case restructure
    case consolidation
    case reconsolidation
    case desirePulse
    case distill
}

public struct ModelRoute: Sendable, Equatable, Decodable {
    public let model: String
    public let effort: String?      // low|medium|high|xhigh|max — la ModelParamPolicy valida por modelo
    public let maxTokens: Int

    enum CodingKeys: String, CodingKey { case model, effort, maxTokens = "max_tokens" }

    public init(model: String, effort: String?, maxTokens: Int) {
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
    }
}

public struct ProviderAPIConfig: Sendable, Equatable, Decodable {
    public let baseURL: URL
    /// Header `anthropic-version` (solo Anthropic).
    public let version: String?
    /// Betas comunes a todo modo de auth (`anthropic-beta`); rotables sin release.
    public let betas: [String]
    /// Betas ADICIONALES por modo de auth. oauth lleva `oauth-2025-04-20`
    /// (obligatoria con Bearer); en api_key NO debe enviarse.
    public let authBetas: [AuthMode: [String]]

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url", version, betas, authBetas = "auth_betas"
    }

    public init(baseURL: URL, version: String?, betas: [String], authBetas: [AuthMode: [String]] = [:]) {
        self.baseURL = baseURL
        self.version = version
        self.betas = betas
        self.authBetas = authBetas
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.baseURL = try c.decode(URL.self, forKey: .baseURL)
        self.version = try c.decodeIfPresent(String.self, forKey: .version)
        self.betas = try c.decodeIfPresent([String].self, forKey: .betas) ?? []
        let raw = try c.decodeIfPresent([String: [String]].self, forKey: .authBetas) ?? [:]
        var modes: [AuthMode: [String]] = [:]
        for (k, v) in raw {
            guard let mode = AuthMode(rawValue: k) else { continue }  // modo futuro: ignorar
            modes[mode] = v
        }
        self.authBetas = modes
    }

    /// Betas efectivas para el request: comunes + las del modo activo.
    public func effectiveBetas(for mode: AuthMode) -> [String] {
        betas + (authBetas[mode] ?? [])
    }
}

/// Config completa de un provider: prompt base + API + rutas del dial.
public struct ProviderConfig: Sendable, Equatable {
    public let systemPromptBase: String
    public let api: ProviderAPIConfig
    public let routes: [TurnClass: ModelRoute]

    public init(systemPromptBase: String, api: ProviderAPIConfig, routes: [TurnClass: ModelRoute]) {
        self.systemPromptBase = systemPromptBase
        self.api = api
        self.routes = routes
    }
}

/// Snapshot inmutable de toda la config remota, congelado por sesión.
public struct ConfigSnapshot: Sendable, Equatable {
    public let providers: [ModelProvider: ProviderConfig]

    public init(providers: [ModelProvider: ProviderConfig]) {
        self.providers = providers
    }

    public func config(for provider: ModelProvider) -> ProviderConfig? {
        providers[provider]
    }
}

// MARK: - Parsing del JSON `provider_config` (forward-compatible)

/// Estructura del parámetro `provider_config` en Remote Config.
/// Claves desconocidas (providers o turn classes futuros) se IGNORAN:
/// una config nueva en la consola jamás debe crashear una app vieja.
public enum ProviderConfigParser {
    public struct Entry: Decodable {
        public let api: ProviderAPIConfig
        public let routes: [String: ModelRoute]
    }

    public static func parse(_ data: Data) throws -> [ModelProvider: (api: ProviderAPIConfig, routes: [TurnClass: ModelRoute])] {
        let raw = try JSONDecoder().decode([String: Entry].self, from: data)
        var out: [ModelProvider: (api: ProviderAPIConfig, routes: [TurnClass: ModelRoute])] = [:]
        for (key, entry) in raw {
            guard let provider = ModelProvider(rawValue: key) else { continue }  // provider futuro: ignorar
            var routes: [TurnClass: ModelRoute] = [:]
            for (routeKey, route) in entry.routes {
                guard let turn = TurnClass(rawValue: routeKey) else { continue } // clase futura: ignorar
                routes[turn] = route
            }
            out[provider] = (entry.api, routes)
        }
        return out
    }

    /// Nombre del parámetro plano del prompt base para un provider.
    public static func promptKey(for provider: ModelProvider) -> String {
        "system_prompt_\(provider.rawValue)"
    }
}

// MARK: - Provider estático (tests, previews y defaults bundled)

public struct StaticConfigProvider: RemoteConfigProviding {
    private let fixed: ConfigSnapshot
    public init(_ snapshot: ConfigSnapshot) { self.fixed = snapshot }
    public func snapshot() -> ConfigSnapshot { fixed }
}
