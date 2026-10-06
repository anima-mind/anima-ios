// AgentLoop.swift — el turno integrado (§4.4, §5.10). Fase 1: el ensamblado usa
// WorkingMemory (orden estable §5.1), la ejecución de tools pasa por el
// Sensorimotor (permisos 2-capas §5.7), y el turno respeta las stop conditions
// completas (maxIter, cancel, presupuesto de tokens, latencia y loop) + relieve
// de presión ante overflow. §5.7 SkillEngine: el skill que matchea el turno se
// inyecta como conocimiento al contexto activado y se practica al cerrar; si
// está AUTOMATIZADO y el match es de alta confianza, el SkillRunner corre antes
// sus pasos aferentes (System 1) y el LLM redacta UNA vez con los resultados.

import Foundation

/// Eventos que el loop emite para la UI (streaming token a token, estados).
public enum LoopEvent: Sendable, Equatable {
    case textDelta(String)
    case thinkingDelta(String)
    case toolStarted(name: String)
    case toolFinished(name: String, isError: Bool)
    case assistantMessage([ContentBlock])   // mensaje del assistant persistido
    case skillAutomated(SkillAutomationSummary)   // el runner ya corrió los aferentes
    case refused
    case turnFinished(stopReason: StopReason?)
    case stopped(StopConditions.Stop)
    case error(String)
    /// El contexto no cabía en el modelo activo: recorte duro determinista.
    case contextTrimmed(model: String)
    /// Cuánto del contexto del modelo ocupa el turno (medidor del chat).
    case context(ContextGauge)
    /// Una tool falló y el texto final no lo admitía: la línea "⚠️ No pude …"
    /// que el loop antepuso al mensaje (la card la muestra con alerta).
    case toolFailure(String)
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
    // Track G (doc 05 §1): la línea de estado corporal (gafas) se refresca cada
    // turno y entra al system volátil. nil ⇒ el turno no cambia en nada.
    private let bodyStatus: (@Sendable () async -> String?)?
    /// Sesión de propósito (taller de skills): system volátil de tarea. nil ⇒ nada cambia.
    private let taskInstructions: String?
    /// Reloj del harness (línea "Ahora: …" del system volátil). nil ⇒ sin reloj.
    private let clock: (@Sendable () -> Date)?

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
        bodyStatus: (@Sendable () async -> String?)? = nil,
        taskInstructions: String? = nil,
        clock: (@Sendable () -> Date)? = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.init(selector: .claudeOnly(provider: provider, router: router, authMode: authMode, token: token),
                  store: store, telemetry: telemetry, clientTools: clientTools, serverTools: serverTools,
                  workingMemory: workingMemory, permissionPolicy: permissionPolicy, confirmation: confirmation,
                  toolTimeout: toolTimeout, stopConditions: stopConditions, retryPolicy: retryPolicy,
                  brain: brain, inbox: inbox, memoryBudget: memoryBudget, selfModel: selfModel,
                  realRegister: realRegister, skillEngine: skillEngine, bodyStatus: bodyStatus,
                  taskInstructions: taskInstructions, clock: clock, sleep: sleep)
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
        bodyStatus: (@Sendable () async -> String?)? = nil,
        taskInstructions: String? = nil,
        clock: (@Sendable () -> Date)? = { Date() },
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
        self.bodyStatus = bodyStatus
        self.taskInstructions = taskInstructions
        self.clock = clock
        self.sleep = sleep
    }

    /// Ejecuta un turno de solo texto. Persiste, corre el tool loop y devuelve un
    /// stream de LoopEvent para la UI.
    public func run(sessionId: SessionID, userText: String) -> AsyncStream<LoopEvent> {
        run(sessionId: sessionId, content: [.text(userText)])
    }

    /// Pista volátil por superficie de origen (el HUD es para vistazos).
    public static let glassesSurfaceHint = "[Superficie: gafas] El dueño te habla por voz desde sus gafas y oirá tu respuesta: responde en 1–2 frases cortas, sin markdown ni listas. Si hace falta más, dilo breve y ofrece verlo en el teléfono."


    /// Turno multimodal: los content blocks (texto + image blocks de una foto, o
    /// texto de un transcript de audio) forman el mensaje user del turno.
    public func run(sessionId: SessionID, content: [ContentBlock],
                    surface: SurfaceID = .phoneChat) -> AsyncStream<LoopEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.runTurn(sessionId: sessionId, content: content, surface: surface,
                                   emit: { continuation.yield($0) })
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runTurn(sessionId: SessionID, content: [ContentBlock], surface: SurfaceID,
                         emit: @escaping @Sendable (LoopEvent) -> Void) async {
        let skillTurn = SkillTurn()
        let end = await runTurnBody(sessionId: sessionId, content: content, surface: surface,
                                    emit: emit, skillTurn: skillTurn)
        await concludeSkill(skillTurn, end: end, sessionId: sessionId)
    }

    /// El cuerpo del turno; cada salida devuelve CÓMO terminó (para practice).
    private func runTurnBody(sessionId: SessionID, content: [ContentBlock], surface: SurfaceID,
                             emit: @escaping @Sendable (LoopEvent) -> Void,
                             skillTurn: SkillTurn) async -> TurnEnd {
        let turnStart = Date()
        do {
            let clientSpecs = await sensorimotor.toolSpecs()
            // Solo el perfil de Claude lleva server tools (web_search es de Anthropic):
            // on-device y OpenAI-compat van sin ellas.
            var allSpecs = clientSpecs + (selector.conversationProfile.reliefMode == .serverSide ? serverTools : [])

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
            let toolProfile = ToolProfile.for(model: route.model)
            allSpecs = toolProfile.apply(allSpecs)
            await workingMemory.updateRestructureBanner(restructureBanner)

            // Fase 3 (§5.5): el render vivo del SelfModel reemplaza al SelfView estático.
            if let selfModel {
                await workingMemory.updateSelfRender(await selfModel.render())
            }

            // Track G: estado corporal volátil (gafas conectadas / solo teléfono)
            // + pista de la superficie de origen del turno.
            if let bodyStatus {
                await workingMemory.updateBodyStatus(await bodyStatus())
            }
            await workingMemory.updateSurfaceHint(surface == .glassesHUD ? Self.glassesSurfaceHint : nil)
            if let taskInstructions { await workingMemory.updateTaskInstructions(taskInstructions) }
            await workingMemory.updateClock(clock?())

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
            // misma posición (máx 1, el de mejor score, truncado al perfil). Si
            // está automatizado y el match supera el umbral alto, entra en su
            // lugar el bloque con los aferentes YA ejecutados.
            if let skillEngine {
                skillTurn.wired = true
                let available = Set(allSpecs.map { LocalToolAdapter.tool(named: $0.name)?.realTool ?? $0.name })
                skillTurn.match = await skillEngine.bestMatch(userText, availableTools: available)
                if let match = skillTurn.match {
                    skillTurn.injection = await runAutomation(match, engine: skillEngine, userText: userText,
                                                              clientTools: Set(clientSpecs.map(\.name)),
                                                              sessionId: sessionId, skillTurn: skillTurn, emit: emit)
                }
                if skillTurn.injection == nil {
                    skillTurn.injection = await workingMemory.setActivatedSkill(skillTurn.match?.skill)
                }
            }

            // Assemble con orden estable (§5.1). El turno del usuario se persiste
            // aparte; los bloques ephemeral (system, activado) no van al transcript.
            let turn = TurnInput(sessionId: sessionId, content: content)
            var messages = try await workingMemory.assemble(turn)
            let systemBase = AppGuide.systemBase(binding.router.systemPromptBase,
                                                 contextBudget: workingMemory.profile.contextBudgetTokens)
            let fit = ContextFit(profile: workingMemory.profile, systemBase: systemBase, tools: allSpecs,
                                 route: route)
            // Nunca un turno imposible: si el ensamblado no cabe en el modelo
            // activo (p.ej. pasar de Claude al de Apple a mitad de conversación),
            // recorte duro ANTES de llamar y frontera persistida.
            let turnSeq = (try store.lastSeq(sessionId: sessionId)) + 1
            if LocalRelief.estimateTokens(messages) > fit.availableTokens {
                messages = try hardTrim(messages, available: fit.availableTokens, sessionId: sessionId,
                                        turnSeq: turnSeq, model: fit.modelName, emit: emit)
            }
            emit(.context(fit.gauge(messages)))
            try store.append(sessionId: sessionId, message: Message(role: .user, content: content), surface: surface)
            // No se escribe al brain en caliente: se encola para el Consolidator (§5.4 a).
            try? inbox?.enqueue(sessionId: sessionId, text: userText, source: "turn")

            var iteration = 1
            var tokensUsed = 0
            var toolCallCount = 0
            var retryCount = 0
            var lastUsage = Usage()
            var loopDetector = LoopDetector(threshold: stopConditions.loopRepeatThreshold)
            var reliefRetried = false
            var hardTrimmed = false
            var failures = TurnFailures()
            // Modelo local: un solo reintento guiado tras un fallo de tool. La
            // primera redirección (consulta en vez de creación) no lo gasta.
            var localToolErrors = 0
            var localRedirected = false
            // Modelo local: ¿alguna tool del turno escribió (no solo leyó)?
            var localWrote = false

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
                let opts = binding.callOpts(route: route, systemPromptBase: systemBase, relief: controls)

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
                    if !hardTrimmed {
                        // El relieve no alcanzó: recorte duro a la mitad del disponible.
                        hardTrimmed = true
                        messages = try hardTrim(messages, available: fit.availableTokens / 2, sessionId: sessionId,
                                                turnSeq: turnSeq, model: fit.modelName, emit: emit)
                        continue
                    }
                    emit(.error(Self.contextExceededMessage))
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
                    try store.append(sessionId: sessionId, message: .assistant(response.content), usage: response.usage,
                                     surface: surface)
                    await logMemoryUsage(activatedIds, sessionId: sessionId)
                    emit(.refused)
                    try? telemetry.record(sessionId: sessionId, turnClass: turnClass, model: route.model,
                                          usage: lastUsage, toolCalls: toolCallCount, retries: retryCount)
                    return .refused
                }

                // Nunca mentir tras un error: si una intención falló y el texto
                // final no lo admite, la línea fija va al frente.
                var content = response.content
                if response.stopReason != .toolUse, response.stopReason != .pauseTurn,
                   let notice = ToolFailureNotice.notice(failures: failures.entries,
                                                         finalText: Self.plainText(response.content)) {
                    content = ToolFailureNotice.prepend(notice, to: content)
                    emit(.toolFailure(notice))
                }
                // Modelo local: pidió cambiar/dar por logrado algo sin tool para eso y
                // el turno cerró sin tools ⇒ dónde se hace, determinista.
                if toolProfile == .onDevice, !localWrote, response.stopReason != .toolUse,
                   response.stopReason != .pauseTurn, let hint = LocalWhen.changeHint(userText),
                   !Self.plainText(content).contains(hint), !Self.plainText(content).lowercased().contains("tab ") {
                    let addition = Self.plainText(content).isEmpty ? hint : "\n\n" + hint
                    emit(.textDelta(addition))
                    content.append(.text(addition))
                }
                let assistantMessage = Message.assistant(content)
                try store.append(sessionId: sessionId, message: assistantMessage, usage: response.usage, surface: surface)
                messages.append(assistantMessage)
                emit(.assistantMessage(content))

                switch response.stopReason {
                case .pauseTurn:
                    iteration += 1
                    continue

                case .toolUse:
                    var results: [ContentBlock] = []
                    var attachments: [ContentBlock] = []
                    for call in response.toolCalls {
                        // Loop detection: misma tool + mismo input N veces seguidas.
                        if loopDetector.record(tool: call.name, input: call.input) {
                            // Lo Real insiste: el bucle es un fallo determinístico (§5.6).
                            await realRegister?.record(.loop(name: call.name, input: call.input,
                                                             sessionId: sessionId, now: Date()))
                            emit(.stopped(.loopDetected))
                            return .stopped(.loopDetected)
                        }
                        // Modelo local: la llamada del adapter se traduce a la tool real
                        // (mismo Sensorimotor); el transcript conserva lo que dijo el modelo.
                        let resolution: LocalToolAdapter.Resolution = toolProfile == .onDevice
                            ? LocalToolAdapter.resolve(name: call.name, input: call.input, now: clock?() ?? Date(),
                                                      ownerText: userText)
                            : .real(name: call.name, input: call.input)
                        let realName: String
                        let realInput: JSONValue
                        var result: ToolResult
                        let verb: String
                        var parameterError = false
                        // Una llamada que el adapter rechaza (redirect, parámetros) es un
                        // artefacto del 3B, no un fallo del mundo: no va al RealRegister
                        // ni al skill (3 redirects armaban un RESTRUCTURE falso).
                        var adapterArtifact = false
                        switch resolution {
                        case .real(let name, let input):
                            realName = name
                            realInput = input
                            verb = ToolFailureNotice.verb(tool: name, input: input)
                            if !LocalToolAdapter.readOnlyTools.contains(call.name) { localWrote = true }
                            emit(.toolStarted(name: name))
                            toolCallCount += 1
                            let executed = await sensorimotor.execute(name: name, input: input)
                            result = toolProfile == .onDevice
                                ? LocalToolAdapter.present(executed, local: call.name, input: input, ownerText: userText)
                                : executed
                            parameterError = LocalToolAdapter.isParameterError(executed.content)
                        case .invalid(let tool, let message):
                            realName = tool
                            realInput = call.input
                            verb = LocalToolAdapter.verb(local: LocalToolAdapter.intended(name: call.name, ownerText: userText))
                            emit(.toolStarted(name: tool))
                            toolCallCount += 1
                            result = ToolResult(content: message, isError: true)
                            parameterError = true
                            adapterArtifact = true
                        }
                        let redirected = adapterArtifact
                            && LocalToolAdapter.intended(name: call.name, ownerText: userText) != call.name
                        if adapterArtifact {
                            // El aviso nunca muestra el texto interno del adapter; un
                            // redirect no es un fallo de la intención.
                            if !redirected {
                                failures.record(verb: verb, result: ToolResult(
                                    content: LocalToolAdapter.ownerFacing(result.content), isError: true))
                            }
                        } else {
                            failures.record(verb: verb, result: result)
                        }
                        if toolProfile == .onDevice, result.isError, !result.isRejection {
                            // Solo los parámetros se corrigen reintentando; un fallo del
                            // mundo (sin permiso, store roto) cierra el turno con el aviso.
                            let intended = LocalToolAdapter.intended(name: call.name, ownerText: userText)
                            if !parameterError {
                                localToolErrors = 2
                            } else if intended != call.name, !localRedirected {
                                localRedirected = true
                            } else {
                                localToolErrors += 1
                            }
                            if parameterError {
                                result.content = LocalToolAdapter.retryHint(tool: intended, message: result.content)
                            }
                        }
                        emit(.toolFinished(name: realName, isError: result.isError))
                        if !adapterArtifact {
                            skillTurn.recordTool(realName, isError: result.isError && !result.isRejection,
                                                 rejected: result.isRejection)
                        }
                        // RealRegister (§5.6): captura el fallo de tool, costo 0 LLM.
                        if result.isError, !adapterArtifact {
                            await realRegister?.record(.tool(name: realName, input: realInput,
                                                             result: result, sessionId: sessionId, now: Date()))
                        }
                        results.append(.toolResult(toolUseId: call.id, content: result.content, isError: result.isError))
                        attachments.append(contentsOf: result.attachments)
                    }
                    // tool_result primero (contrato de la API), luego los adjuntos
                    // (la foto POV entra al contexto por el pipeline de imagen).
                    let toolMessage = Message.user(results + attachments)
                    try store.append(sessionId: sessionId, message: toolMessage, surface: surface)
                    messages.append(toolMessage)
                    // Modelo local: el reintento guiado ya se gastó y volvió a
                    // fallar ⇒ el turno cierra con el aviso, sin otra llamada.
                    if toolProfile == .onDevice, localToolErrors >= 2,
                       let notice = ToolFailureNotice.notice(failures: failures.entries, finalText: "") {
                        emit(.textDelta(notice))
                        emit(.toolFailure(notice))
                        let closing = Message.assistant([.text(notice)])
                        try store.append(sessionId: sessionId, message: closing, surface: surface)
                        emit(.assistantMessage(closing.content))
                        await logMemoryUsage(activatedIds, sessionId: sessionId)
                        try? telemetry.record(sessionId: sessionId, turnClass: turnClass, model: route.model,
                                              usage: lastUsage, toolCalls: toolCallCount, retries: retryCount)
                        emit(.turnFinished(stopReason: .endTurn))
                        return .finished(.endTurn)
                    }
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

    /// System 1 con guardias de System 2 (§5.7, §B.6): corre los aferentes de un
    /// skill automatizado. Devuelve el bloque inyectado, o nil ⇒ el turno cae a
    /// inyección de conocimiento normal (abort neutral o desautomatización).
    private func runAutomation(_ match: SkillMatch, engine: SkillEngine, userText: String,
                               clientTools: Set<String>, sessionId: SessionID, skillTurn: SkillTurn,
                               emit: @escaping @Sendable (LoopEvent) -> Void) async -> SkillInjection? {
        guard match.score >= SkillEngine.automationThreshold,
              let compiled = await engine.automatize(match.skill.name) else { return nil }
        let context = SkillRunContext(turnText: userText, now: await engine.currentDate())
        let sensorimotor = self.sensorimotor
        let run = await SkillRunner.run(compiled, context: context, availableTools: clientTools) { name, input in
            await sensorimotor.executePreauthorized(name: name, input: input)
        }
        skillTurn.automation = run
        if run.completed {
            emit(.skillAutomated(run.summary))
            return await workingMemory.setActivatedAutomation(run, skill: compiled.skill)
        }
        // Desautomatización dirigida por lo Real: el fallo entra al RealRegister
        // como patrón (la taxonomía de siempre); el practice(.failure) lo aplica
        // concludeSkill al cerrar el turno.
        if run.abort?.punishes == true, let call = run.failedCall, let result = run.failedResult {
            await realRegister?.record(.tool(name: call.tool, input: call.input, result: result,
                                             sessionId: sessionId, now: Date()))
        }
        return nil
    }

    /// Cierre del turno para el SkillEngine: practice del skill inyectado según
    /// cómo terminó + telemetría de match/inyección/outcome (una fila por turno).
    private func concludeSkill(_ skillTurn: SkillTurn, end: TurnEnd, sessionId: SessionID) async {
        guard let skillEngine, skillTurn.wired else { return }
        var outcome = skillTurn.match.map { _ in
            SkillTurn.outcome(end: end, skillToolFailed: skillTurn.skillToolErrors > 0,
                              ownerRejected: skillTurn.skillToolRejections > 0) }
        // Un aferente automatizado que falló (o un deny) rompe la racha aunque el
        // turno luego cierre bien por inyección: el compilado ya no es confiable.
        if skillTurn.automation?.abort?.punishes == true { outcome = .failure }
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
            skillToolErrors: skillTurn.skillToolErrors,
            automatized: skillTurn.automation != nil,
            automatedSteps: skillTurn.automation?.executed.count ?? 0,
            automationAbort: skillTurn.automation?.abort?.rawValue))
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

    public static let contextExceededMessage = "Contexto excedido aún tras recortar la conversación."

    /// Recorte duro + frontera persistida (la ventana de los próximos turnos
    /// arranca en lo que se conservó) + aviso al chat.
    private func hardTrim(_ messages: [Message], available: Int, sessionId: SessionID, turnSeq: Int,
                          model: String, emit: @Sendable (LoopEvent) -> Void) throws -> [Message] {
        let boundary = try store.currentBoundary(sessionId: sessionId)
        let result = HardTrim.apply(messages, availableTokens: available)
        guard result.didTrim else { return messages }
        let keepsSummary = result.messages.first.map(Self.isSummary) ?? false
        let keptRows = result.keptHistory - (keepsSummary ? 1 : 0)
        try store.addBoundary(sessionId: sessionId, kind: .trim, fromSeq: turnSeq - keptRows,
                              summary: keepsSummary ? boundary?.summary : nil, model: model)
        emit(.contextTrimmed(model: model))
        return result.messages
    }

    static func isSummary(_ message: Message) -> Bool {
        guard message.role == .user, case .text(let t)? = message.content.first else { return false }
        return t.hasPrefix(ContextBoundary.summaryHeader)
    }

    /// "Reintentar" tras un contexto excedido: frontera de recorte que deja solo
    /// los últimos `keepTurns` turnos visibles en la ventana.
    public func trimHistory(sessionId: SessionID, keepTurns: Int = 2) throws {
        let from = try store.trimStart(sessionId: sessionId, keepTurns: keepTurns)
        let model = selector.binding(for: .interactive).map { ModelNames.friendly($0.router.route(.interactive).model) }
        try store.addBoundary(sessionId: sessionId, kind: .trim, fromSeq: from, model: model)
    }

    /// El medidor sin turno en curso (al abrir el chat o al cambiar de modelo).
    public func contextGauge(sessionId: SessionID) async -> ContextGauge? {
        guard let binding = selector.binding(for: .interactive) else { return nil }
        let route = binding.router.route(.interactive)
        let specs = ToolProfile.for(model: route.model).apply(await sensorimotor.toolSpecs()
            + (selector.conversationProfile.reliefMode == .serverSide ? serverTools : []))
        let systemBase = AppGuide.systemBase(binding.router.systemPromptBase,
                                             contextBudget: workingMemory.profile.contextBudgetTokens)
        let fit = ContextFit(profile: workingMemory.profile, systemBase: systemBase, tools: specs, route: route)
        guard let messages = try? await workingMemory.assemble(TurnInput(sessionId: sessionId, content: [])) else {
            return nil
        }
        return fit.gauge(messages.filter { !$0.content.isEmpty })
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
    /// El run del SkillRunner (nil ⇒ el skill no estaba automatizado o el match
    /// no superó el umbral alto).
    var automation: SkillRun?
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
