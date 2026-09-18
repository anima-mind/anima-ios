// AgentLoop.swift — el turno integrado (§4.4, §5.10). Fase 1: el ensamblado usa
// WorkingMemory (orden estable §5.1), la ejecución de tools pasa por el
// Sensorimotor (permisos 2-capas §5.7), y el turno respeta las stop conditions
// completas (maxIter, cancel, presupuesto de tokens, latencia y loop) + relieve
// de presión ante overflow.

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
    private let workingMemory: WorkingMemory
    private let sensorimotor: Sensorimotor
    private let telemetry: Telemetry
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
        clientTools: [any SensorimotorTool],
        serverTools: [ToolSpec] = [WebSearchTool.spec],
        workingMemory: WorkingMemory? = nil,
        permissionPolicy: PermissionPolicy = .init(),
        confirmation: ConfirmationProvider = FailClosedConfirmation(),
        toolTimeout: TimeInterval = 30,
        stopConditions: StopConditions = .init(),
        retryPolicy: RetryPolicy = .init(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.provider = provider
        self.store = store
        self.workingMemory = workingMemory ?? WorkingMemory(store: store)
        self.sensorimotor = Sensorimotor(tools: clientTools, policy: permissionPolicy,
                                         confirmation: confirmation, timeout: toolTimeout)
        self.telemetry = telemetry
        self.serverTools = serverTools
        self.router = router
        self.authMode = authMode
        self.token = token
        self.stopConditions = stopConditions
        self.retryPolicy = retryPolicy
        self.sleep = sleep
    }

    /// Ejecuta un turno de solo texto. Persiste, corre el tool loop y devuelve un
    /// stream de LoopEvent para la UI.
    public func run(sessionId: SessionID, userText: String) -> AsyncStream<LoopEvent> {
        run(sessionId: sessionId, content: [.text(userText)])
    }

    /// Turno multimodal: los content blocks (texto + image blocks de una foto, o
    /// texto de un transcript de audio) forman el mensaje user del turno.
    public func run(sessionId: SessionID, content: [ContentBlock]) -> AsyncStream<LoopEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.runTurn(sessionId: sessionId, content: content, emit: { continuation.yield($0) })
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runTurn(sessionId: SessionID, content: [ContentBlock], emit: @escaping @Sendable (LoopEvent) -> Void) async {
        let turnStart = Date()
        do {
            let route = router.route(.interactive)
            let clientSpecs = await sensorimotor.toolSpecs()
            let allSpecs = clientSpecs + serverTools

            // Assemble con orden estable (§5.1). El turno del usuario se persiste
            // aparte; los bloques ephemeral (system, activado) no van al transcript.
            let turn = TurnInput(sessionId: sessionId, content: content)
            var messages = try await workingMemory.assemble(turn)
            try store.append(sessionId: sessionId, message: Message(role: .user, content: content))

            var iteration = 1
            var tokensUsed = 0
            var toolCallCount = 0
            var retryCount = 0
            var lastUsage = Usage()
            var loopDetector = LoopDetector(threshold: stopConditions.loopRepeatThreshold)
            var reliefRetried = false

            while true {
                let elapsed = Date().timeIntervalSince(turnStart)
                switch stopConditions.evaluate(iteration: iteration, tokensUsed: tokensUsed, elapsed: elapsed, isCancelled: Task.isCancelled) {
                case .none: break
                case .cancelled: emit(.stopped(.cancelled)); return
                case .maxIterations: emit(.stopped(.maxIterations)); return
                case .budgetExceeded: emit(.stopped(.budgetExceeded)); return
                case .latencyExceeded: emit(.stopped(.latencyExceeded)); return
                case .loopDetected: emit(.stopped(.loopDetected)); return
                }

                // Controles de gestión de contexto para este request (escalera por presión).
                let controls = await workingMemory.consumeRelief()
                let opts = CallOpts(route: route, api: router.api, authMode: authMode,
                                    token: token, systemPromptBase: router.systemPromptBase, relief: controls)

                let response: ProviderResponse
                do {
                    let attempts = Counter()
                    response = try await streamOnce(
                        ctx: AssembledContext(messages: messages), tools: allSpecs, opts: opts, attempts: attempts, emit: emit)
                    retryCount += max(0, attempts.value - 1)
                } catch ClassifiedError.contextOverflow {
                    // Sobrevive el overflow vía relieve: aliviar y reintentar UNA vez.
                    if !reliefRetried {
                        reliefRetried = true
                        _ = await workingMemory.relieve(.clearStaleToolResults)
                        _ = await workingMemory.relieve(.compact)
                        continue
                    }
                    emit(.error("Contexto excedido aún tras aliviar la presión."))
                    return
                } catch let error as ClassifiedError {
                    emit(.error(Self.describe(error)))
                    return
                } catch {
                    emit(.error(error.localizedDescription))
                    return
                }

                lastUsage = response.usage
                tokensUsed += response.usage.inputTokens + response.usage.outputTokens
                await workingMemory.recordTurnUsage(response.usage)

                // refusal: chequear ANTES de usar el content; mostrar sin crash, NO reintentar.
                if response.stopReason == .refusal {
                    try store.append(sessionId: sessionId, message: .assistant(response.content), usage: response.usage)
                    emit(.refused)
                    try? telemetry.record(sessionId: sessionId, turnClass: .interactive, model: route.model,
                                          usage: lastUsage, toolCalls: toolCallCount, retries: retryCount)
                    return
                }

                let assistantMessage = Message.assistant(response.content)
                try store.append(sessionId: sessionId, message: assistantMessage, usage: response.usage)
                messages.append(assistantMessage)
                emit(.assistantMessage(response.content))

                switch response.stopReason {
                case .pauseTurn:
                    iteration += 1
                    continue

                case .toolUse:
                    var results: [ContentBlock] = []
                    for call in response.toolCalls {
                        // Loop detection: misma tool + mismo input N veces seguidas.
                        if loopDetector.record(tool: call.name, input: call.input) {
                            emit(.stopped(.loopDetected))
                            return
                        }
                        emit(.toolStarted(name: call.name))
                        toolCallCount += 1
                        let result = await sensorimotor.execute(name: call.name, input: call.input)
                        emit(.toolFinished(name: call.name, isError: result.isError))
                        results.append(.toolResult(toolUseId: call.id, content: result.content, isError: result.isError))
                    }
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
        tools: [ToolSpec],
        opts: CallOpts,
        attempts: Counter,
        emit: @Sendable @escaping (LoopEvent) -> Void
    ) async throws -> ProviderResponse {
        try await withRetry(policy: retryPolicy, sleep: sleep) { attempt in
            attempts.set(attempt)
            let forwarded = ForwardedFlag()
            do {
                return try await self.provider.completeCollecting(ctx, tools: tools, opts: opts) { event in
                    switch event {
                    case .textDelta(let t): forwarded.mark(); emit(.textDelta(t))
                    case .thinkingDelta(let t): forwarded.mark(); emit(.thinkingDelta(t))
                    default: break
                    }
                }
            } catch let error as ClassifiedError {
                if forwarded.value {
                    throw ClassifiedError.fatal(status: -1, message: Self.describe(error))
                }
                throw error
            }
        }
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
