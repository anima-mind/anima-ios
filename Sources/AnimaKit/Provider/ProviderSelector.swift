// ProviderSelector.swift — los 3 modos de operación (§4.9) y qué córtex corre
// cada TurnClass. El harness es local por construcción; el provider es solo el
// córtex intercambiable:
//
//   Solo teléfono (gratis) → OnDeviceProvider para TODO, conversación incluida.
//   Remoto                 → el córtex remoto activo (Claude, OpenAI o Gemini)
//                            para todo (§4.7).
//   Híbrido                → conversación/restructure en el remoto; sueño, pulsos
//                            y destilado en el teléfono (con caída al remoto si
//                            el modelo local deja de estar disponible).
//
// QUÉ remoto (Anthropic/OpenAI/Google) es ortogonal al modo: lo guarda
// RemoteProviderStore y lo lleva el RemoteCortex.

import Foundation

// MARK: - Modo

public enum OperatingMode: String, Sendable, CaseIterable, Codable {
    case onDeviceOnly = "on_device_only"
    /// Córtex remoto para todo. rawValue "claude" por compatibilidad con los
    /// UserDefaults persistidos antes de que el remoto fuera intercambiable.
    case remote = "claude"
    case hybrid

    public var title: String { title(remote: .anthropic) }
    public var summary: String { summary(remote: .anthropic) }

    public func title(remote: ModelProvider) -> String {
        switch self {
        case .onDeviceOnly: return "Solo este teléfono · gratis"
        case .remote: return remote.displayName
        case .hybrid: return "Híbrido"
        }
    }

    public func summary(remote: ModelProvider) -> String {
        switch self {
        case .onDeviceOnly: return "Todo corre en el modelo de Apple: sin red, sin costo."
        case .remote: return "Todo corre en \(remote.displayName) con tu key."
        case .hybrid: return "Conversas con \(remote.displayName); el sueño corre en tu teléfono, gratis."
        }
    }

    /// Necesita el token del provider remoto en Keychain.
    public var requiresToken: Bool { self != .onDeviceOnly }
    /// Necesita el modelo local (Apple Intelligence).
    public var requiresOnDevice: Bool { self != .remote }
}

/// Persistencia del modo (UserDefaults; jamás secretos). @unchecked: UserDefaults
/// es thread-safe pero no declara Sendable.
public struct OperatingModeStore: @unchecked Sendable {
    public static let key = "anima.operatingMode"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// El modo elegido; `nil` si nunca se eligió.
    public var storedMode: OperatingMode? {
        defaults.string(forKey: Self.key).flatMap(OperatingMode.init(rawValue:))
    }

    /// El modo efectivo: instalaciones previas a §4.9 (sin modo guardado) son remotas.
    public var mode: OperatingMode { storedMode ?? .remote }

    public func set(_ mode: OperatingMode) {
        defaults.set(mode.rawValue, forKey: Self.key)
    }
}

// MARK: - Backend y binding

public enum ProviderBackend: String, Sendable, Equatable {
    case onDevice
    case remote

    public var label: String { label(remote: .anthropic) }

    public func label(remote: ModelProvider) -> String {
        switch self {
        case .onDevice: return ModelProvider.onDevice.displayName
        case .remote: return remote.displayName
        }
    }
}

extension ContextProfile {
    public static func forBackend(_ backend: ProviderBackend, remote: ModelProvider = .anthropic) -> ContextProfile {
        switch backend {
        case .onDevice: return .onDevice
        case .remote: return remote.usesOpenAICompatWire ? .openAICompat : .claude
        }
    }
}

/// Todo lo que un consumidor (AgentLoop, Consolidator, DesireEngine) necesita
/// para llamar al córtex de una clase de turno.
public struct ProviderBinding: Sendable {
    public let backend: ProviderBackend
    /// Qué provider atiende la llamada (el remoto activo u on_device).
    public var kind: ModelProvider = .anthropic
    public let provider: Provider
    public let router: ModelRouter
    public let authMode: AuthMode
    public let token: String

    public func callOpts(route: ModelRoute, systemPromptBase: String? = nil,
                         relief: ReliefControls = .init()) -> CallOpts {
        CallOpts(route: route, api: router.api, authMode: authMode, token: token,
                 systemPromptBase: systemPromptBase ?? router.systemPromptBase, relief: relief)
    }
}

// MARK: - Selector

public struct ProviderSelector: Sendable {
    /// Córtex remoto con la key del dueño: Claude, OpenAI o Gemini (`kind`).
    public struct RemoteCortex: Sendable {
        public let provider: Provider
        public let router: ModelRouter
        public let authMode: AuthMode
        public let token: String
        public let kind: ModelProvider
        public init(provider: Provider, router: ModelRouter, authMode: AuthMode, token: String,
                    kind: ModelProvider = .anthropic) {
            self.provider = provider
            self.router = router
            self.authMode = authMode
            self.token = token
            self.kind = kind
        }
    }

    /// Córtex local: el modelo de Apple con la entrada `on_device` del dial.
    public struct LocalCortex: Sendable {
        public let provider: Provider
        public let router: ModelRouter
        public init(provider: Provider, router: ModelRouter) {
            self.provider = provider
            self.router = router
        }
    }

    /// Clases que en Híbrido corren en el teléfono: el sueño, los pulsos y el destilado.
    public static let hybridLocalClasses: Set<TurnClass> = [.consolidation, .reconsolidation, .desirePulse, .distill]

    public let mode: OperatingMode
    public let remote: RemoteCortex?
    public let local: LocalCortex?
    private let availability: @Sendable () -> OnDeviceAvailability

    public init(mode: OperatingMode, remote: RemoteCortex?, local: LocalCortex?,
                availability: @escaping @Sendable () -> OnDeviceAvailability) {
        self.mode = mode
        self.remote = remote
        self.local = local
        self.availability = availability
    }

    /// Selector de un solo córtex Claude (el comportamiento previo a §4.9).
    public static func claudeOnly(provider: Provider, router: ModelRouter,
                                  authMode: AuthMode, token: String) -> ProviderSelector {
        ProviderSelector(mode: .remote,
                         remote: RemoteCortex(provider: provider, router: router, authMode: authMode, token: token),
                         local: nil, availability: { .deviceNotEligible })
    }

    /// El provider remoto activo (Anthropic si no hay córtex remoto cableado).
    public var remoteKind: ModelProvider { remote?.kind ?? .anthropic }

    /// Título del modo con el nombre del remoto activo.
    public var modeTitle: String { mode.title(remote: remoteKind) }

    /// Backend PLANEADO por modo y clase (tabla del §4.9, sin mirar availability).
    public static func plannedBackend(mode: OperatingMode, turn: TurnClass) -> ProviderBackend {
        switch mode {
        case .onDeviceOnly: return .onDevice
        case .remote: return .remote
        case .hybrid: return hybridLocalClasses.contains(turn) ? .onDevice : .remote
        }
    }

    /// Backend EFECTIVO: en Híbrido, si el modelo local no está (o no se cableó),
    /// la clase cae al remoto. En Solo teléfono no hay caída: sin modelo local el
    /// turno falla con el porqué (jamás gasta el token del dueño a escondidas).
    public func backend(for turn: TurnClass) -> ProviderBackend {
        let planned = Self.plannedBackend(mode: mode, turn: turn)
        guard mode == .hybrid, planned == .onDevice else { return planned }
        guard local != nil, availability().isAvailable else { return remote != nil ? .remote : .onDevice }
        return .onDevice
    }

    /// El córtex para una clase de turno; `nil` si el modo pide un córtex que no
    /// está cableado (p.ej. remoto sin token).
    public func binding(for turn: TurnClass) -> ProviderBinding? {
        switch backend(for: turn) {
        case .remote:
            guard let remote else { return nil }
            return ProviderBinding(backend: .remote, kind: remote.kind, provider: remote.provider,
                                   router: remote.router, authMode: remote.authMode, token: remote.token)
        case .onDevice:
            guard let local else { return nil }
            // Híbrido: si la disponibilidad cae A MITAD (entre el check y la
            // llamada, o assets desaparecidos), la llamada cae al remoto.
            let provider: Provider
            if mode == .hybrid, let remote {
                provider = FallbackProvider(primary: local.provider, fallback: remote, turn: turn)
            } else {
                provider = local.provider
            }
            // Sin red, sin auth: el token/AuthMode no se usan en local.
            return ProviderBinding(backend: .onDevice, kind: .onDevice, provider: provider,
                                   router: local.router, authMode: .apiKey, token: "")
        }
    }

    /// Perfil de contexto de la conversación (lo que ve la WorkingMemory del loop).
    public var conversationProfile: ContextProfile {
        .forBackend(Self.plannedBackend(mode: mode, turn: .interactive), remote: remoteKind)
    }

    /// El sueño necesita red solo si corre en el remoto (BGProcessingTask).
    public var sleepRequiresNetwork: Bool {
        backend(for: .consolidation) == .remote
    }
}

// MARK: - Caída al remoto (Híbrido)

/// Provider del Híbrido para las clases locales: intenta el modelo local y, si
/// reporta no-disponible ANTES de emitir contenido, repite la llamada en el
/// remoto con su ruta y credenciales (el system prompt de la tarea se conserva).
public struct FallbackProvider: Provider {
    let primary: Provider
    let fallback: ProviderSelector.RemoteCortex
    let turn: TurnClass

    public func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        let primary = self.primary
        let fallback = self.fallback
        let turn = self.turn
        return AsyncThrowingStream { continuation in
            let task = Task {
                var emittedContent = false
                do {
                    for try await event in primary.complete(ctx, tools: tools, opts: opts) {
                        switch event {
                        case .textDelta, .thinkingDelta, .toolUseStart, .toolUseInputDelta:
                            emittedContent = true
                        default: break
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch let error as ClassifiedError {
                    guard case .fatal(let status, _) = error, status == OnDeviceProvider.unavailableStatus,
                          !emittedContent else {
                        continuation.finish(throwing: error)
                        return
                    }
                    let base = fallback.router.route(turn)
                    let route = ModelRoute(
                        model: base.model,
                        effort: ModelParamPolicy.policy(for: base.model).allowsEffort ? base.effort : nil,
                        maxTokens: base.maxTokens)
                    let fallbackOpts = CallOpts(route: route, api: fallback.router.api, authMode: fallback.authMode,
                                                token: fallback.token, systemPromptBase: opts.systemPromptBase)
                    do {
                        for try await event in fallback.provider.complete(ctx, tools: tools, opts: fallbackOpts) {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
