// AgentLoop.swift — el turno integrado (§4.4, §5.10). Fase 1: el ensamblado usa
// WorkingMemory (orden estable §5.1), la ejecución de tools pasa por el
// Sensorimotor (permisos 2-capas §5.7), y el turno respeta las stop conditions
// completas (maxIter, cancel, presupuesto de tokens, latencia y loop) + relieve
// de presión ante overflow. §5.7 SkillEngine: el skill que matchea el turno se
// inyecta como conocimiento al contexto activado y se practica al cerrar.

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
    // §5.7: skills = conocimiento procedural; nil ⇒ el turno no cambia en nada.
    private let skillEngine: SkillEngine?

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
        skillEngine: SkillEngine? = nil,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.init(selector: .claudeOnly(provider: provider, router: router, authMode: authMode, token: token),
                  store: store, telemetry: telemetry, clientTools: clientTools, serverTools: serverTools,
                  workingMemory: workingMemory, permissionPolicy: permissionPolicy, confirmation: confirmation,
                  toolTimeout: toolTimeout, stopConditions: stopConditions, retryPolicy: retryPolicy,
                  brain: brain, inbox: inbox, memoryBudget: memoryBudget, selfModel: selfModel,
                  realRegister: realRegister, skillEngine: skillEngine, sleep: sleep)
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
        skillEngine: SkillEngine? = nil,
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
        self.skillEngine = skillEngine
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
        let skillTurn = SkillTurn()
        let end = await runTurnBody(sessionId: sessionId, content: content, emit: emit, skillTurn: skillTurn)
        await concludeSkill(skillTurn, end: end, sessionId: sessionId)
    }

    /// El cuerpo del turno; cada salida devuelve CÓMO terminó (para practice).
    private func runTurnBody(sessionId: SessionID, content: [ContentBlock],
                             emit: @escaping @Sendable (LoopEvent) -> Void,
                             skillTurn: SkillTurn) async -> TurnEnd {
        let turnStart = Date()
        do {
            let clientSpecs = await sensorimotor.toolSpecs()
            // Solo el perfil de Claude lleva server tools (web_search es de Anthropic):
            // on-device y OpenAI-compat van sin ellas.
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
                emit(.error("El modo \(selector.modeTitle) no tiene un modelo configurado (¿falta el token?)."))
                return .error
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

            // §5.7: el skill que matchea el turno entra como CONOCIMIENTO en la
            // misma posición (máx 1, el de mejor score, truncado al perfil).
            if let skillEngine {
                skillTurn.wired = true
                let available = Set(allSpecs.map(\.name))
                skillTurn.match = await skillEngine.bestMatch(userText, availableTools: available)
                skillTurn.injection = await workingMemory.setActivatedSkill(skillTurn.match?.skill)
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
                let stop = stopConditions.evaluate(iteration: iteration, tokensUsed: tokensUsed,
                                                   elapsed: elapsed, isCancelled: Task.isCancelled)
                if stop != .none {
                    emit(.stopped(stop))
                    return .stopped(stop)
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
                    return .error
                } catch let error as ClassifiedError {
                    // Fatal del provider: lo Real lo registra (§5.6) antes de rendirse.
                    if case .fatal = error {
                        await realRegister?.record(.classified(toolName: "provider", error: error,
                                                               sessionId: sessionId, now: Date()))
                    }
                    emit(.error(Self.describe(error)))
                    return .error
                } catch {
                    emit(.error(error.localizedDescription))
                    return .error
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
                    return .refused
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
                            return .stopped(.loopDetected)
                        }
                        emit(.toolStarted(name: call.name))
                        toolCallCount += 1
                        let result = await sensorimotor.execute(name: call.name, input: call.input)
                        emit(.toolFinished(name: call.name, isError: result.isError))
                        skillTurn.recordTool(call.name, isError: result.isError && !result.isRejection, rejected: result.isRejection)
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
                    return .finished(response.stopReason)
                }
            }
        } catch {
            emit(.error(error.localizedDescription))
            return .error
        }
    }

    /// Cierre del turno para el SkillEngine: practice del skill inyectado según
    /// cómo terminó + telemetría de match/inyección/outcome (una fila por turno).
    private func concludeSkill(_ skillTurn: SkillTurn, end: TurnEnd, sessionId: SessionID) async {
        guard let skillEngine, skillTurn.wired else { return }
        let outcome = skillTurn.match.map { _ in
            SkillTurn.outcome(end: end, skillToolFailed: skillTurn.skillToolErrors > 0,
                              ownerRejected: skillTurn.skillToolRejections > 0) }
        if let name = skillTurn.match?.skill.name, let outcome {
            await skillEngine.practice(name, outcome: outcome)
        }
        try? telemetry.recordSkillTurn(.init(
            sessionId: sessionId,
            skillName: skillTurn.match?.skill.name,
            score: skillTurn.match?.score,
            injectedChars: skillTurn.injection?.text.count ?? 0,
            truncated: skillTurn.injection?.truncated ?? false,
            outcome: outcome?.rawValue ?? "none",
            endReason: end.label,
            skillToolCalls: skillTurn.skillToolCalls,
            skillToolErrors: skillTurn.skillToolErrors))
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

/// Cómo terminó un turno (para el practice del skill inyectado).
enum TurnEnd: Equatable {
    case finished(StopReason?)
    case stopped(StopConditions.Stop)
    case refused
    case error

    var label: String {
        switch self {
        case .finished(let reason): return reason.map { "\($0)" } ?? "none"
        case .stopped(let stop): return "stopped:\(stop)"
        case .refused: return "refused"
        case .error: return "error"
        }
    }
}

/// Estado del skill durante un turno. Vive dentro del actor (no cruza hilos).
final class SkillTurn {
    var wired = false
    var match: SkillMatch?
    var injection: SkillInjection?
    private(set) var skillToolCalls = 0
    private(set) var skillToolErrors = 0
    private(set) var skillToolRejections = 0

    /// Solo cuentan las tools que el skill toca (pasos + requires_tools).
    func recordTool(_ name: String, isError: Bool, rejected: Bool = false) {
        guard let match, match.skill.toolNames.contains(name) else { return }
        skillToolCalls += 1
        if isError { skillToolErrors += 1 }
        if rejected { skillToolRejections += 1 }
    }

    /// Criterio de éxito (§5.7 practice): cerró endTurn y ninguna tool del skill
    /// falló ⇒ success; una tool del skill falló o el turno se detuvo por stop
    /// condition (loop, presupuesto, latencia, maxIter, cancel) ⇒ failure; lo
    /// demás (error del provider, refusal, max_tokens) no dice nada del skill ⇒ neutral.
    static func outcome(end: TurnEnd, skillToolFailed: Bool, ownerRejected: Bool = false) -> SkillOutcome {
        if skillToolFailed { return .failure }
        // "No quiero" ≠ "falló": un rechazo del dueño no castiga NI refuerza la
        // racha — el turno completo queda neutral aunque cierre en endTurn.
        if ownerRejected { return .neutral }
        switch end {
        case .finished(.endTurn): return .success
        case .stopped: return .failure
        case .finished, .refused, .error: return .neutral
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
