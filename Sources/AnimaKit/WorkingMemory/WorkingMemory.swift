// WorkingMemory.swift — el episodic buffer del turno (§5.1). Ensambla el array
// `messages[]` con ORDEN ESTABLE para maximizar el prompt caching del prefijo
// (tools + system top-level los arma el ClaudeRequestBuilder; aquí vive lo que
// va DENTRO de messages[]).
//
// Orden de ensamblado (§5.1):
//   1. bloques compaction   — re-anexados cada turno si el server los emitió
//   2. history window       — la ventana del SymbolicStore
//   3. role:system mid-conv — SelfModel view (§4.5); Fase 1: SelfView estático
//   4. role:user activado   — memorias del Brain.retrieve() + el skill que matcheó
//                             el turno ([SKILL: …], conocimiento activado)
//   5. turn input           — el mensaje del dueño (+ image blocks si hay foto)
//
// Lo volátil (3, 4) va al final: el caché cubre el prefijo, moverlo al frente
// destruiría el hit rate.

import Foundation

/// La entrada de un turno: los content blocks del mensaje del dueño (texto y/o
/// imágenes) para una sesión.
public struct TurnInput: Sendable, Equatable {
    public var sessionId: SessionID
    public var content: [ContentBlock]

    public init(sessionId: SessionID, content: [ContentBlock]) {
        self.sessionId = sessionId
        self.content = content
    }

    public static func text(_ text: String, sessionId: SessionID) -> TurnInput {
        .init(sessionId: sessionId, content: [.text(text)])
    }
}

/// Estrategias de alivio de presión (§5.1), escalera mecánico→inteligente.
public enum ReliefStrategy: Sendable, Equatable {
    case clearStaleToolResults   // context-management beta (clear_tool_uses_20250919)
    case compact                 // compaction server-side (compact-2026-01-12)
    case evictToBrain            // cross-session; hook Fase 2
}

/// Buffer episódico por sesión. Actor: la presión, la corrección de estimación y
/// los bloques compaction son estado mutable de sesión.
public actor WorkingMemory {
    private let store: SymbolicStore
    private let budgetTokens: Int
    /// Perfil del provider activo (§4.9): presupuesto, history window, memorias
    /// activadas y modo de relieve. Claude por default (comportamiento previo).
    public nonisolated let profile: ContextProfile
    private var selfView: ProvisionalSelfView
    // Fase 3: el render vivo del SelfModel (§5.5) reemplaza al SelfView estático
    // cuando el loop lo empuja cada turno. nil ⇒ se usa selfView.render().
    private var selfRenderOverride: String?
    // Fase 3 (§5.6): banner de restructure inyectado cuando el turno matchea un
    // patrón demanding del RealRegister. Va como segundo mid-conversation system.
    private var restructureBanner: String?

    // Bloques compaction emitidos por el server; se re-anexan cada turno (contrato beta).
    private var compactionBlocks: [ContentBlock] = []
    // Hook Fase 2: el Brain inyecta aquí las memorias activadas del turno.
    private var activatedMemories: [ContentBlock] = []
    // El skill del turno (SkillEngine.bestMatch), ya renderizado y truncado.
    private var activatedSkill: SkillInjection?

    // Estimación de presión: chars del último ensamblado × ratio de corrección.
    private var lastAssembledChars = 0
    private var correctionRatio = 1.0 / 3.6
    private var pendingRelief = ReliefControls()

    public init(store: SymbolicStore,
                selfView: ProvisionalSelfView = .provisional,
                budgetTokens: Int? = nil,
                profile: ContextProfile = .claude) {
        self.store = store
        self.profile = profile
        self.budgetTokens = budgetTokens ?? profile.contextBudgetTokens
        self.selfView = selfView
    }

    /// Modo de relieve del provider activo.
    public nonisolated var reliefMode: ContextProfile.ReliefMode { profile.reliefMode }

    // MARK: - Ensamblado (orden estable §5.1)

    public func assemble(_ turn: TurnInput) throws -> [Message] {
        var messages: [Message] = []

        // 1. bloques compaction re-anexados (si el server los emitió).
        if !compactionBlocks.isEmpty {
            messages.append(Message(role: .assistant, content: compactionBlocks))
        }

        // 2. history window desde el transcript canónico.
        //    En on-device la ventana es corta (presupuesto del perfil).
        let history = try store.window(sessionId: turn.sessionId, budgetTokens: profile.historyBudgetTokens)
        messages.append(contentsOf: history)

        // 3. mid-conversation system message — SelfModel view vivo (§4.5, §5.5) o,
        //    sin SelfModel cableado, el SelfView estático provisional (Fase 1).
        //    Va DESPUÉS del history y ANTES del turn input.
        messages.append(Message(role: .system, content: [.text(selfRenderOverride ?? selfView.render())]))

        // 3b. banner de restructure (§5.6): autoridad de operador para que el
        //     turno cambie de aproximación ante un patrón que insiste en fallar.
        if let restructureBanner, !restructureBanner.isEmpty {
            messages.append(Message(role: .system, content: [.text(restructureBanner)]))
        }

        // 4. contexto activado — memorias del Brain (Fase 2: vacío por ahora).
        let activated = assembleActivatedContext()
        messages.append(contentsOf: activated)

        // 5. turn input.
        messages.append(Message(role: .user, content: turn.content))

        lastAssembledChars = messages.reduce(0) { acc, message in
            acc + message.content.reduce(0) { $0 + SymbolicStore.approxChars($1) }
        }
        return messages
    }

    /// Hook Fase 2: formatea las memorias activadas como bloque etiquetado
    /// "[MEMORIAS ACTIVADAS — pueden estar desactualizadas]". Vacío en Fase 1.
    private func assembleActivatedContext() -> [Message] {
        // El skill es conocimiento activado, misma naturaleza que las memorias:
        // mismo mensaje, después de ellas (más cerca del turn input).
        let content = activatedMemories + (activatedSkill.map { [ContentBlock.text($0.text)] } ?? [])
        guard !content.isEmpty else { return [] }
        return [Message(role: .user, content: content)]
    }

    // MARK: - Presión y relieve

    /// Presión estimada = tokens estimados / presupuesto. Heurística chars/3.6
    /// corregida con el `usage` real del turno anterior (sin llamada de counting).
    public var pressure: Double {
        guard budgetTokens > 0 else { return 0 }
        let estimatedTokens = Double(lastAssembledChars) * correctionRatio
        return estimatedTokens / Double(budgetTokens)
    }

    /// Corrige el ratio de estimación con el tamaño real del prompt del turno
    /// anterior (input + cache read + cache creation ≈ tamaño del prefijo+mensajes).
    public func recordTurnUsage(_ usage: Usage) {
        let realPromptTokens = usage.inputTokens
            + (usage.cacheReadInputTokens ?? 0)
            + (usage.cacheCreationInputTokens ?? 0)
        if lastAssembledChars > 0, realPromptTokens > 0 {
            correctionRatio = Double(realPromptTokens) / Double(lastAssembledChars)
        }
    }

    /// Aplica una estrategia de alivio. Devuelve los controles a incluir en el
    /// próximo request (el server hace el trabajo — cero llamadas propias en
    /// clear/compact). `evictToBrain` es hook de Fase 2.
    @discardableResult
    public func relieve(_ strategy: ReliefStrategy) -> ReliefControls {
        // On-device jamás marca controles server-side (usa relieveLocally).
        guard profile.reliefMode == .serverSide else { return ReliefControls() }
        switch strategy {
        case .clearStaleToolResults:
            pendingRelief.clearStaleToolResults = true
        case .compact:
            pendingRelief.compact = true
        case .evictToBrain:
            break   // Fase 2: el Consolidator decide qué sobrevive al cierre de sesión.
        }
        return pendingRelief
    }

    /// Controles de relieve para el próximo request, combinando lo pendiente con
    /// la escalera automática por presión (§5.1: >0.7 clear, >0.85 compact).
    public func requestControls() -> ReliefControls {
        // On-device: las betas context-management/compaction son de Anthropic y
        // NO existen aquí — el relieve es mecánico local (relieveLocally).
        guard profile.reliefMode == .serverSide else { return ReliefControls() }
        return pendingRelief.merged(with: PressureRelief.plan(pressure: pressure))
    }

    /// Relieve mecánico local (on-device) sobre los messages del turno en curso:
    /// trim de tool results viejos + history más corta. Devuelve lo desalojado
    /// para que el loop lo encole al Brain. En serverSide no toca nada.
    public func relieveLocally(_ messages: [Message], force: Bool = false) -> LocalRelief.Result {
        guard profile.reliefMode == .localMechanical else {
            return LocalRelief.Result(messages: messages, evicted: [], didRelieve: false)
        }
        let result = LocalRelief.apply(messages, budgetTokens: budgetTokens, force: force)
        if result.didRelieve {
            lastAssembledChars = result.messages.reduce(0) { acc, message in
                acc + message.content.reduce(0) { $0 + SymbolicStore.approxChars($1) }
            }
        }
        return result
    }

    /// El loop consume los controles y los limpia tras enviarlos al server.
    public func consumeRelief() -> ReliefControls {
        let controls = requestControls()
        pendingRelief = ReliefControls()
        return controls
    }

    /// Ingesta de los bloques compaction del `response.content` para re-anexarlos
    /// en los turnos siguientes (obligación del contrato beta compact-2026-01-12).
    public func ingestCompaction(_ blocks: [ContentBlock]) {
        guard !blocks.isEmpty else { return }
        compactionBlocks = blocks
    }

    /// Etiqueta del bloque de contexto activado (§5.1 posición 6). Va como datos,
    /// no como instrucción — defensa ante prompt injection en memorias.
    public static let activatedMemoriesHeader = "[MEMORIAS ACTIVADAS — pueden estar desactualizadas]"

    /// Fase 2: el Brain empuja aquí las memorias activadas del turno.
    public func setActivatedMemories(_ blocks: [ContentBlock]) {
        activatedMemories = blocks
    }

    /// Fase 2: formatea las memorias recuperadas del Brain como un único bloque
    /// etiquetado (role:user, posición 6 del §5.1). Vacío ⇒ no anexa nada.
    public func setActivatedMemories(_ memories: [ActivatedMemory]) {
        guard !memories.isEmpty else { activatedMemories = []; return }
        // On-device: solo las top-N (el retrieve ya viene ordenado por relevancia).
        let body = memories.prefix(profile.maxActivatedMemories).map { "- \($0.content)" }.joined(separator: "\n")
        activatedMemories = [.text(Self.activatedMemoriesHeader + "\n" + body)]
    }

    /// El skill que matcheó el turno (nil lo limpia), renderizado como bloque
    /// `[SKILL: …]` y truncado al presupuesto del perfil activo.
    @discardableResult
    public func setActivatedSkill(_ skill: Skill?) -> SkillInjection? {
        activatedSkill = skill.map { SkillInjection.render($0, budgetChars: profile.maxSkillChars) }
        return activatedSkill
    }

    /// Fase 3: el SelfModel vivo reemplaza al SelfView estático provisional.
    public func updateSelfView(_ view: ProvisionalSelfView) {
        selfView = view
    }

    /// Fase 3 (§5.5): el loop empuja el render vivo del SelfModel cada turno.
    public func updateSelfRender(_ render: String) {
        selfRenderOverride = render
    }

    /// Fase 3 (§5.6): fija (o limpia con nil) el banner de restructure del turno.
    public func updateRestructureBanner(_ banner: String?) {
        restructureBanner = banner
    }
}
