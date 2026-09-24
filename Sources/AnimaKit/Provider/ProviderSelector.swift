// ProviderSelector.swift — los 3 modos de operación (§4.9) y qué córtex corre
// cada TurnClass. El harness es local por construcción; el provider es solo el
// córtex intercambiable:
//
//   Solo teléfono (gratis) → OnDeviceProvider para TODO, conversación incluida.
//   Claude                 → ClaudeProvider para todo (§4.7).
//   Híbrido                → conversación/restructure en Claude; sueño, pulsos y
//                            destilado en el teléfono (con caída a Claude si el
//                            modelo local deja de estar disponible).

import Foundation

// MARK: - Modo

public enum OperatingMode: String, Sendable, CaseIterable, Codable {
    case onDeviceOnly = "on_device_only"
    case claude
    case hybrid

    public var title: String {
        switch self {
        case .onDeviceOnly: return "Solo este teléfono · gratis"
        case .claude: return "Claude"
        case .hybrid: return "Híbrido"
        }
    }

    public var summary: String {
        switch self {
        case .onDeviceOnly: return "Todo corre en el modelo de Apple: sin red, sin costo."
        case .claude: return "Todo corre en Claude con tu token."
        case .hybrid: return "Conversas con Claude; el sueño corre en tu teléfono, gratis."
        }
    }

    /// Necesita el token de Anthropic en Keychain.
    public var requiresToken: Bool { self != .onDeviceOnly }
    /// Necesita el modelo local (Apple Intelligence).
    public var requiresOnDevice: Bool { self != .claude }
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

    /// El modo efectivo: instalaciones previas a §4.9 (sin modo guardado) son Claude.
    public var mode: OperatingMode { storedMode ?? .claude }

    public func set(_ mode: OperatingMode) {
        defaults.set(mode.rawValue, forKey: Self.key)
    }
}

// MARK: - Backend y binding

public enum ProviderBackend: String, Sendable, Equatable {
    case onDevice
    case claude

    public var label: String {
        switch self {
        case .onDevice: return "este teléfono"
        case .claude: return "Claude"
        }
    }
}

extension ContextProfile {
    public static func forBackend(_ backend: ProviderBackend) -> ContextProfile {
        backend == .onDevice ? .onDevice : .claude
    }
}

/// Todo lo que un consumidor (AgentLoop, Consolidator, DesireEngine) necesita
/// para llamar al córtex de una clase de turno.
public struct ProviderBinding: Sendable {
    public let backend: ProviderBackend
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
    /// Córtex remoto: Claude con el token del dueño.
    public struct ClaudeCortex: Sendable {
        public let provider: Provider
        public let router: ModelRouter
        public let authMode: AuthMode
        public let token: String
        public init(provider: Provider, router: ModelRouter, authMode: AuthMode, token: String) {
            self.provider = provider
            self.router = router
            self.authMode = authMode
            self.token = token
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
    public let claude: ClaudeCortex?
    public let local: LocalCortex?
    private let availability: @Sendable () -> OnDeviceAvailability

    public init(mode: OperatingMode, claude: ClaudeCortex?, local: LocalCortex?,
                availability: @escaping @Sendable () -> OnDeviceAvailability) {
        self.mode = mode
        self.claude = claude
        self.local = local
        self.availability = availability
    }

    /// Selector de un solo córtex Claude (el comportamiento previo a §4.9).
    public static func claudeOnly(provider: Provider, router: ModelRouter,
                                  authMode: AuthMode, token: String) -> ProviderSelector {
        ProviderSelector(mode: .claude,
                         claude: ClaudeCortex(provider: provider, router: router, authMode: authMode, token: token),
                         local: nil, availability: { .deviceNotEligible })
    }

    /// Backend PLANEADO por modo y clase (tabla del §4.9, sin mirar availability).
    public static func plannedBackend(mode: OperatingMode, turn: TurnClass) -> ProviderBackend {
        switch mode {
        case .onDeviceOnly: return .onDevice
        case .claude: return .claude
        case .hybrid: return hybridLocalClasses.contains(turn) ? .onDevice : .claude
        }
    }

    /// Backend EFECTIVO: en Híbrido, si el modelo local no está (o no se cableó),
    /// la clase cae a Claude. En Solo teléfono no hay caída: sin modelo local el
    /// turno falla con el porqué (jamás gasta el token del dueño a escondidas).
    public func backend(for turn: TurnClass) -> ProviderBackend {
        let planned = Self.plannedBackend(mode: mode, turn: turn)
        guard mode == .hybrid, planned == .onDevice else { return planned }
        guard local != nil, availability().isAvailable else { return claude != nil ? .claude : .onDevice }
        return .onDevice
    }

    /// El córtex para una clase de turno; `nil` si el modo pide un córtex que no
    /// está cableado (p.ej. Claude sin token).
    public func binding(for turn: TurnClass) -> ProviderBinding? {
        switch backend(for: turn) {
        case .claude:
            guard let claude else { return nil }
            return ProviderBinding(backend: .claude, provider: claude.provider, router: claude.router,
                                   authMode: claude.authMode, token: claude.token)
        case .onDevice:
            guard let local else { return nil }
            // Híbrido: si la disponibilidad cae A MITAD (entre el check y la
            // llamada, o assets desaparecidos), la llamada cae a Claude.
            let provider: Provider = (mode == .hybrid && claude != nil)
                ? FallbackProvider(primary: local.provider, fallback: claude!, turn: turn)
                : local.provider
            // Sin red, sin auth: el token/AuthMode no se usan en local.
            return ProviderBinding(backend: .onDevice, provider: provider, router: local.router,
                                   authMode: .apiKey, token: "")
        }
    }

    /// Perfil de contexto de la conversación (lo que ve la WorkingMemory del loop).
    public var conversationProfile: ContextProfile {
        .forBackend(Self.plannedBackend(mode: mode, turn: .interactive))
    }

    /// El sueño necesita red solo si corre en Claude (BGProcessingTask).
    public var sleepRequiresNetwork: Bool {
        backend(for: .consolidation) == .claude
    }
}

// MARK: - Caída a Claude (Híbrido)

/// Provider del Híbrido para las clases locales: intenta el modelo local y, si
/// reporta no-disponible ANTES de emitir contenido, repite la llamada en Claude
/// con la ruta y credenciales de Claude (el system prompt de la tarea se conserva).
public struct FallbackProvider: Provider {
    let primary: Provider
    let fallback: ProviderSelector.ClaudeCortex
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
