// AgentLoop.swift — el turno integrado (§4.4, §5.10): assemble mínimo → stream →
// tool loop → persist. Fase 0 sin WorkingMemory completo: el prefijo son los
// system blocks del config + el historial de la sesión desde el SymbolicStore.

import Foundation

/// Eventos que el loop emite para la UI (streaming token a token, estados).
public enum LoopEvent: Sendable, Equatable {
    case textDelta(String)
    case thinkingDelta(String)
    case toolStarted(name: String)
    case toolFinished(name: String, isError: Bool)
    case assistantMessage([ContentBlock])   // mensaje del assistant persistido
    case refused
    case turnFinished(stopReason: StopReason?)
    case stopped(StopConditions.Stop)
    case error(String)
}

public actor AgentLoop {
    private let provider: Provider
    private let store: SymbolicStore
    private let telemetry: Telemetry
    private let tools: [HarnessTool]
    private let serverTools: [ToolSpec]
    private let router: ModelRouter
    private let authMode: AuthMode
    private let token: String
    private let stopConditions: StopConditions
    private let retryPolicy: RetryPolicy
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        provider: Provider,
        store: SymbolicStore,
        telemetry: Telemetry,
        router: ModelRouter,
        authMode: AuthMode,
        token: String,
        clientTools: [HarnessTool],
        serverTools: [ToolSpec] = [WebSearchTool.spec],
        stopConditions: StopConditions = .init(),
        retryPolicy: RetryPolicy = .init(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.provider = provider
        self.store = store
        self.telemetry = telemetry
        self.router = router
        self.authMode = authMode
        self.token = token
        self.tools = clientTools
        self.serverTools = serverTools
        self.stopConditions = stopConditions
        self.retryPolicy = retryPolicy
        self.sleep = sleep
    }

    private var allToolSpecs: [ToolSpec] { tools.map(\.spec) + serverTools }

    /// Ejecuta un turno. Persiste el mensaje del usuario, corre el tool loop y
    /// devuelve un stream de LoopEvent para la UI.
    public func run(sessionId: SessionID, userText: String) -> AsyncStream<LoopEvent> {
        AsyncStream { continuation in
            let task = Task { await self.runTurn(sessionId: sessionId, userText: userText, emit: { continuation.yield($0) }); continuation.finish() }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runTurn(sessionId: SessionID, userText: String, emit: @escaping @Sendable (LoopEvent) -> Void) async {
        do {
            let route = router.route(.interactive)
            let opts = CallOpts(route: route, api: router.api, authMode: authMode,
                                token: token, systemPromptBase: router.systemPromptBase)

            // Assemble: historial + turno del usuario.
            var messages = try store.window(sessionId: sessionId)
            let userMessage = Message.user(userText)
            try store.append(sessionId: sessionId, message: userMessage)
            messages.append(userMessage)

            var iteration = 1
            var tokensUsed = 0
            var toolCallCount = 0
            var retryCount = 0
            var lastUsage = Usage()

            while true {
                switch stopConditions.evaluate(iteration: iteration, tokensUsed: tokensUsed, isCancelled: Task.isCancelled) {
                case .none: break
                case .cancelled: emit(.stopped(.cancelled)); return
                case .maxIterations: emit(.stopped(.maxIterations)); return
                case .budgetExceeded: emit(.stopped(.budgetExceeded)); return
                }

                // Un intento de streaming, con retry ante errores previos a cualquier delta.
                let response: ProviderResponse
                do {
                    let attempts = Counter()
                    response = try await streamOnce(
                        ctx: AssembledContext(messages: messages),
                        opts: opts,
                        attempts: attempts,
                        emit: emit)
                    retryCount += max(0, attempts.value - 1)
                } catch let error as ClassifiedError {
                    emit(.error(Self.describe(error)))
                    return
                } catch {
                    emit(.error(error.localizedDescription))
                    return
                }

                lastUsage = response.usage
                tokensUsed += response.usage.inputTokens + response.usage.outputTokens

                // refusal: chequear ANTES de usar el content; mostrar sin crash, NO reintentar.
                if response.stopReason == .refusal {
                    try store.append(sessionId: sessionId, message: .assistant(response.content), usage: response.usage)
                    emit(.refused)
                    try? telemetry.record(sessionId: sessionId, turnClass: .interactive, model: route.model,
                                          usage: lastUsage, toolCalls: toolCallCount, retries: retryCount)
                    return
                }

                // Persistir + reflejar el mensaje del assistant.
                let assistantMessage = Message.assistant(response.content)
                try store.append(sessionId: sessionId, message: assistantMessage, usage: response.usage)
                messages.append(assistantMessage)
                emit(.assistantMessage(response.content))

                switch response.stopReason {
                case .pauseTurn:
                    // Server tools (web_search): reenviar el content tal cual para continuar.
                    iteration += 1
                    continue

                case .toolUse:
                    var results: [ContentBlock] = []
                    for call in response.toolCalls {
                        emit(.toolStarted(name: call.name))
                        toolCallCount += 1
                        let result = await execute(call: call)
                        emit(.toolFinished(name: call.name, isError: result.isError))
                        results.append(.toolResult(toolUseId: call.id, content: result.content, isError: result.isError))
                    }
                    // TODOS los tool_results de la ronda en UN mensaje user.
                    let toolMessage = Message.user(results)
                    try store.append(sessionId: sessionId, message: toolMessage)
                    messages.append(toolMessage)
                    iteration += 1
                    continue

                case .maxTokens, .endTurn, .stopSequence, .refusal, .none:
                    try? telemetry.record(sessionId: sessionId, turnClass: .interactive, model: route.model,
                                          usage: lastUsage, toolCalls: toolCallCount, retries: retryCount)
                    emit(.turnFinished(stopReason: response.stopReason))
                    return
                }
            }
        } catch {
            emit(.error(error.localizedDescription))
        }
    }

    /// Un intento de completar (con retry ante errores previos a cualquier delta).
    /// Si ya se emitieron deltas y falla, se propaga sin reintentar (evita doble stream).
    private func streamOnce(
        ctx: AssembledContext,
        opts: CallOpts,
        attempts: Counter,
        emit: @Sendable @escaping (LoopEvent) -> Void
    ) async throws -> ProviderResponse {
        try await withRetry(policy: retryPolicy, sleep: sleep) { attempt in
            attempts.set(attempt)
            let forwarded = ForwardedFlag()
            do {
                return try await self.provider.completeCollecting(ctx, tools: self.allToolSpecs, opts: opts) { event in
                    switch event {
                    case .textDelta(let t): forwarded.mark(); emit(.textDelta(t))
                    case .thinkingDelta(let t): forwarded.mark(); emit(.thinkingDelta(t))
                    default: break
                    }
                }
            } catch let error as ClassifiedError {
                // Si ya hubo deltas, no reintentar (el turno se re-persistiría duplicado).
                if forwarded.value {
                    throw ClassifiedError.fatal(status: -1, message: Self.describe(error))
                }
                throw error
            }
        }
    }

    private func execute(call: (id: String, name: String, input: JSONValue)) async -> ToolResult {
        guard let tool = tools.first(where: { $0.spec.name == call.name }) else {
            return ToolResult(content: "Tool desconocida: \(call.name)", isError: true)
        }
        return await tool.execute(call.input)
    }

    static func describe(_ error: ClassifiedError) -> String {
        switch error {
        case .retryable(let a): return "Error transitorio (reintentar en \(a ?? 0)s)."
        case .rateLimited(let a): return "Límite de tasa (retry-after \(a ?? 0)s)."
        case .contextOverflow: return "Contexto excedido."
        case .fatal(let status, let message): return "Error \(status): \(message)"
        }
    }
}

/// Bandera thread-safe para saber si ya se reenviaron deltas en el intento actual.
private final class ForwardedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func mark() { lock.lock(); _value = true; lock.unlock() }
}

/// Contador thread-safe para el número de intentos del último streamOnce.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: Int) { lock.lock(); _value = v; lock.unlock() }
}
