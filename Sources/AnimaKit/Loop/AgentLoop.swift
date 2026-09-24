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
    /// Qué córtex corre cada TurnClass (§4.9: Solo teléfono / Claude / Híbrido).
    private let selector: ProviderSelector
    private let store: SymbolicStore
    private let workingMemory: WorkingMemory
    private let sensorimotor: Sensorimotor
    private let telemetry: Telemetry
    private let serverTools: [ToolSpec]
    private let stopConditions: StopConditions
    private let retryPolicy: RetryPolicy
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    // Fase 2 (§5.10): el Brain inyecta memorias activadas y recibe el usage_log;
    // el inbox recibe los hechos declarados por el dueño para el Consolidator.
    private let brain: Brain?
    private let inbox: ConsolidationInbox?
    private let memoryBudget: Int
    // Fase 3 (§5.5, §5.6): el SelfModel vivo se renderiza al system del turno; el
    // RealRegister recibe los fallos y demanda restructures (rutea a .restructure).
    private let selfModel: SelfModel?
    private let realRegister: RealRegister?

    /// Init de un solo córtex Claude (comportamiento previo a §4.9).
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
        brain: Brain? = nil,
        inbox: ConsolidationInbox? = nil,
        memoryBudget: Int = 8,
        selfModel: SelfModel? = nil,
        realRegister: RealRegister? = nil,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.init(selector: .claudeOnly(provider: provider, router: router, authMode: authMode, token: token),
                  store: store, telemetry: telemetry, clientTools: clientTools, serverTools: serverTools,
                  workingMemory: workingMemory, permissionPolicy: permissionPolicy, confirmation: confirmation,
                  toolTimeout: toolTimeout, stopConditions: stopConditions, retryPolicy: retryPolicy,
                  brain: brain, inbox: inbox, memoryBudget: memoryBudget, selfModel: selfModel,
                  realRegister: realRegister, sleep: sleep)
    }

    /// Init por modo de operación: el selector decide el córtex de cada turno y
    /// el perfil de contexto de la WorkingMemory (§4.9).
    public init(
        selector: ProviderSelector,
        store: SymbolicStore,
        telemetry: Telemetry,
        clientTools: [any SensorimotorTool],
        serverTools: [ToolSpec] = [WebSearchTool.spec],
        workingMemory: WorkingMemory? = nil,
        permissionPolicy: PermissionPolicy = .init(),
        confirmation: ConfirmationProvider = FailClosedConfirmation(),
        toolTimeout: TimeInterval = 30,
        stopConditions: StopConditions = .init(),
        retryPolicy: RetryPolicy = .init(),
        brain: Brain? = nil,
        inbox: ConsolidationInbox? = nil,
        memoryBudget: Int = 8,
        selfModel: SelfModel? = nil,
        realRegister: RealRegister? = nil,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.selector = selector
        self.store = store
        self.workingMemory = workingMemory ?? WorkingMemory(store: store, profile: selector.conversationProfile)
        self.sensorimotor = Sensorimotor(tools: clientTools, policy: permissionPolicy,
                                         confirmation: confirmation, timeout: toolTimeout)
        self.telemetry = telemetry
        self.serverTools = serverTools
        self.stopConditions = stopConditions
        self.retryPolicy = retryPolicy
        self.brain = brain
        self.inbox = inbox
        self.memoryBudget = memoryBudget
        self.selfModel = selfModel
        self.realRegister = realRegister
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
            let clientSpecs = await sensorimotor.toolSpecs()
            // On-device: sin server tools (web_search necesita red y es de Anthropic).
            let allSpecs = clientSpecs + (selector.conversationProfile.reliefMode == .serverSide ? serverTools : [])

            // Restructure (§5.6): si un patrón demanding matchea una tool disponible,
            // el turno se rutea a .restructure (Opus effort high) y se inyecta un
            // banner de autoridad con el historial del patrón.
            var turnClass: TurnClass = .interactive
            var restructureBanner: String?
            if let realRegister {
                let demanding = await realRegister.demand()
                if let match = demanding.first(where: { req in allSpecs.contains { $0.name == req.toolName } }) {
                    restructureBanner = "[RESTRUCTURE] " + match.summary
                    turnClass = .restructure
                }
            }
            guard let binding = selector.binding(for: turnClass) else {
                emit(.error("El modo \(selector.mode.title) no tiene un modelo configurado (¿falta el token?)."))
                return
            }
            let route = binding.router.route(turnClass)
            await workingMemory.updateRestructureBanner(restructureBanner)

            // Fase 3 (§5.5): el render vivo del SelfModel reemplaza al SelfView estático.
            if let selfModel {
                await workingMemory.updateSelfRender(await selfModel.render())
            }

            // Contexto activado (§5.1 posición 6): el Brain recupera para ESTE turno
            // y las memorias entran como bloque etiquetado antes del turn input.
            let userText = Self.plainText(content)
            var activatedIds: [MemoryID] = []
            if let brain {
                let limit = min(memoryBudget, workingMemory.profile.maxActivatedMemories)
                let activated = (try? await brain.retrieve(
                    MemoryQuery(text: userText, turnRef: sessionId, limit: limit))) ?? []
                activatedIds = activated.map(\.id)
                await workingMemory.setActivatedMemories(activated)
            }

            // Assemble con orden estable (§5.1). El turno del usuario se persiste
            // aparte; los bloques ephemeral (system, activado) no van al transcript.
            let turn = TurnInput(sessionId: sessionId, content: content)
            var messages = try await workingMemory.assemble(turn)
            try store.append(sessionId: sessionId, message: Message(role: .user, content: content))
            // No se escribe al brain en caliente: se encola para el Consolidator (§5.4 a).
            try? inbox?.enqueue(sessionId: sessionId, text: userText, source: "turn")

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

                // On-device (§4.9): relieve mecánico local ANTES de llamar si la
                // presión lo pide — trim de tool results + evict al Brain.
                if workingMemory.reliefMode == .localMechanical {
                    let local = await workingMemory.relieveLocally(messages)
                    messages = local.messages
                    evictToBrain(local.evicted, sessionId: sessionId)
                }

                // Controles de gestión de contexto para este request (escalera por
                // presión). En on-device siempre vacíos: jamás betas de Anthropic.
                let controls = await workingMemory.consumeRelief()
                let opts = binding.callOpts(route: route, relief: controls)

                let response: ProviderResponse
                do {
                    let attempts = Counter()
                    response = try await streamOnce(
                        provider: binding.provider,
                        ctx: AssembledContext(messages: messages), tools: allSpecs, opts: opts, attempts: attempts, emit: emit)
                    retryCount += max(0, attempts.value - 1)
                } catch ClassifiedError.contextOverflow {
                    // Sobrevive el overflow vía relieve: aliviar y reintentar UNA vez.
                    if !reliefRetried {
                        reliefRetried = true
                        if workingMemory.reliefMode == .localMechanical {
                            let local = await workingMemory.relieveLocally(messages, force: true)
                            messages = local.messages
                            evictToBrain(local.evicted, sessionId: sessionId)
                        } else {
                            _ = await workingMemory.relieve(.clearStaleToolResults)
                            _ = await workingMemory.relieve(.compact)
                        }
                        continue
                    }
                    emit(.error("Contexto excedido aún tras aliviar la presión."))
                    return
                } catch let error as ClassifiedError {
                    // Fatal del provider: lo Real lo registra (§5.6) antes de rendirse.
                    if case .fatal = error {
                        await realRegister?.record(.classified(toolName: "provider", error: error,
                                                               sessionId: sessionId, now: Date()))
                    }
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
                    await logMemoryUsage(activatedIds, sessionId: sessionId)
                    emit(.refused)
                    try? telemetry.record(sessionId: sessionId, turnClass: turnClass, model: route.model,
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
                            // Lo Real insiste: el bucle es un fallo determinístico (§5.6).
                            await realRegister?.record(.loop(name: call.name, input: call.input,
                                                             sessionId: sessionId, now: Date()))
                            emit(.stopped(.loopDetected))
                            return
                        }
                        emit(.toolStarted(name: call.name))
                        toolCallCount += 1
                        let result = await sensorimotor.execute(name: call.name, input: call.input)
                        emit(.toolFinished(name: call.name, isError: result.isError))
                        // RealRegister (§5.6): captura el fallo de tool, costo 0 LLM.
                        if result.isError {
                            await realRegister?.record(.tool(name: call.name, input: call.input,
                                                             result: result, sessionId: sessionId, now: Date()))
                        }
                        results.append(.toolResult(toolUseId: call.id, content: result.content, isError: result.isError))
                    }
                    let toolMessage = Message.user(results)
                    try store.append(sessionId: sessionId, message: toolMessage)
                    messages.append(toolMessage)
                    iteration += 1
                    continue

                case .maxTokens, .endTurn, .stopSequence, .refusal, .none:
                    await logMemoryUsage(activatedIds, sessionId: sessionId)
                    try? telemetry.record(sessionId: sessionId, turnClass: turnClass, model: route.model,
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
        provider: Provider,
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
                return try await provider.completeCollecting(ctx, tools: tools, opts: opts) { event in
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

    /// Evict al Brain (§4.9, relieve local): el texto desalojado del contexto se
    /// encola como candidato para el Consolidator — se pierde el texto, no el insight.
    /// Los turnos del dueño ya se encolaron al llegar; aquí van las respuestas.
    private func evictToBrain(_ evicted: [Message], sessionId: SessionID) {
        guard let inbox else { return }
        for message in evicted where message.role == .assistant {
            let text = Self.plainText(message.content)
            if !text.isEmpty { try? inbox.enqueue(sessionId: sessionId, text: text, source: "evict") }
        }
    }

    /// usage_log del turno (§5.3 hook del régimen): cada memoria activada se
    /// registra como usada. La heurística de `contradicted` la aplica el ciclo.
    private func logMemoryUsage(_ ids: [MemoryID], sessionId: SessionID) async {
        guard let brain, !ids.isEmpty else { return }
        for id in ids {
            try? await brain.usageLog(memoryId: id, sessionId: sessionId, outcome: .success)
        }
    }

    /// Texto plano del turno del dueño (concatena los bloques de texto).
    static func plainText(_ content: [ContentBlock]) -> String {
        content.compactMap { block in
            if case .text(let t) = block { return t } else { return nil }
        }.joined(separator: "\n")
    }

    static func describe(_ error: ClassifiedError) -> String {
        switch error {
        case .retryable(let a): return "Error transitorio (reintentar en \(a ?? 0)s)."
        case .rateLimited(let a): return "Límite de tasa (retry-after \(a ?? 0)s)."
        case .contextOverflow: return "Contexto excedido."
        case .fatal(let status, let message)
            where status == OnDeviceProvider.unavailableStatus || status == OnDeviceProvider.failureStatus:
            return message   // modelo local: el porqué ya viene legible
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
