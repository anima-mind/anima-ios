// RemoteProvider.swift — el córtex remoto es intercambiable (§4.9): Anthropic
// (ClaudeProvider) u OpenAI/Google (OpenAICompatProvider). Aquí vive qué provider
// remoto está activo (UserDefaults, jamás secretos) y la fábrica del córtex.

import Foundation

extension ModelProvider {
    /// Los providers que corren en la nube con la key del dueño.
    public static let remoteCases: [ModelProvider] = [.anthropic, .openai, .google]

    public var isRemote: Bool { self != .onDevice }

    /// Hablan el wire Chat Completions (OpenAICompatProvider).
    public var usesOpenAICompatWire: Bool { self == .openai || self == .google }

    /// Nombre corto para UI ("Conversas con …").
    public var displayName: String {
        switch self {
        case .anthropic: return "Claude"
        case .openai: return "OpenAI"
        case .google: return "Gemini"
        case .onDevice: return "este teléfono"
        }
    }

    /// Placeholder del campo de la key.
    public var tokenPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openai: return "sk-…"
        case .google: return "AIza…"
        case .onDevice: return ""
        }
    }

    /// Provider probable por el prefijo del token. Solo HINT para la UI, jamás
    /// un gate: las keys cambian de formato sin aviso.
    public static func hint(fromToken token: String) -> ModelProvider? {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("sk-ant-") { return .anthropic }
        if t.hasPrefix("sk-") { return .openai }
        if t.hasPrefix("AIza") { return .google }
        return nil
    }

    /// Formato mínimo aceptable para intentar validar. Anthropic exige su prefijo
    /// (define el AuthMode); los compat solo exigen algo no vacío y sin espacios.
    public func acceptsTokenFormat(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .anthropic: return AuthMode.detect(fromToken: t) != nil
        case .openai, .google: return !t.isEmpty && !t.contains(where: \.isWhitespace)
        case .onDevice: return false
        }
    }

    /// AuthMode con el que viaja el token. En compat no aplica (siempre Bearer):
    /// `.apiKey` es solo el marcador neutro.
    public func authMode(forToken token: String) -> AuthMode? {
        switch self {
        case .anthropic: return AuthMode.detect(fromToken: token)
        case .openai, .google: return acceptsTokenFormat(token) ? .apiKey : nil
        case .onDevice: return nil
        }
    }
}

/// Provider remoto activo (UserDefaults; jamás secretos). Instalaciones previas
/// (sin valor guardado) son Anthropic. @unchecked: UserDefaults es thread-safe
/// pero no declara Sendable.
public struct RemoteProviderStore: @unchecked Sendable {
    public static let key = "anima.remoteProvider"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var storedProvider: ModelProvider? {
        defaults.string(forKey: Self.key).flatMap(ModelProvider.init(rawValue:)).flatMap { $0.isRemote ? $0 : nil }
    }

    public var provider: ModelProvider { storedProvider ?? .anthropic }

    public func set(_ provider: ModelProvider) {
        guard provider.isRemote else { return }
        defaults.set(provider.rawValue, forKey: Self.key)
    }
}

/// Fábrica del córtex remoto: el provider correcto según el `ModelProvider`.
public enum RemoteCortexFactory {
    public static func make(kind: ModelProvider, config: ProviderConfig?, token: String,
                            session: URLSession = .shared) -> ProviderSelector.RemoteCortex? {
        guard kind.isRemote, let config, let authMode = kind.authMode(forToken: token) else { return nil }
        let provider: Provider = kind.usesOpenAICompatWire
            ? OpenAICompatProvider(session: session)
            : ClaudeProvider(session: session)
        return .init(provider: provider, router: ModelRouter(config: config),
                     authMode: authMode, token: token, kind: kind)
    }
}
