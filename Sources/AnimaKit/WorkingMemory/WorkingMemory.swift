// WorkingMemory.swift — el episodic buffer del turno (§5.1). Ensambla el array
// `messages[]` con ORDEN ESTABLE para maximizar el prompt caching del prefijo
// (tools + system top-level los arma el ClaudeRequestBuilder; aquí vive lo que
// va DENTRO de messages[]).
//
// Orden de ensamblado (§5.1):
//   1. bloques compaction   — re-anexados cada turno si el server los emitió
//   2. history window       — la ventana del SymbolicStore
//   3. role:system mid-conv — SelfModel view (§4.5); Fase 1: SelfView estático
//   4. role:user activado   — memorias del Brain.retrieve() (Fase 2: hook vacío)
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
    private var selfView: ProvisionalSelfView

    // Bloques compaction emitidos por el server; se re-anexan cada turno (contrato beta).
    private var compactionBlocks: [ContentBlock] = []
    // Hook Fase 2: el Brain inyecta aquí las memorias activadas del turno.
    private var activatedMemories: [ContentBlock] = []

    // Estimación de presión: chars del último ensamblado × ratio de corrección.
    private var lastAssembledChars = 0
    private var correctionRatio = 1.0 / 3.6
    private var pendingRelief = ReliefControls()

    public init(store: SymbolicStore,
                selfView: ProvisionalSelfView = .provisional,
                budgetTokens: Int = 180_000) {
        self.store = store
        self.budgetTokens = budgetTokens
        self.selfView = selfView
    }

    // MARK: - Ensamblado (orden estable §5.1)

    public func assemble(_ turn: TurnInput) throws -> [Message] {
        var messages: [Message] = []

        // 1. bloques compaction re-anexados (si el server los emitió).
        if !compactionBlocks.isEmpty {
            messages.append(Message(role: .assistant, content: compactionBlocks))
        }

        // 2. history window desde el transcript canónico.
        let history = try store.window(sessionId: turn.sessionId)
        messages.append(contentsOf: history)

        // 3. mid-conversation system message — SelfView estático provisional (§4.5).
        //    Va DESPUÉS del history y ANTES del turn input.
        messages.append(Message(role: .system, content: [.text(selfView.render())]))

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
        guard !activatedMemories.isEmpty else { return [] }
        return [Message(role: .user, content: activatedMemories)]
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
        pendingRelief.merged(with: PressureRelief.plan(pressure: pressure))
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

    /// Fase 2: el Brain empuja aquí las memorias activadas del turno.
    public func setActivatedMemories(_ blocks: [ContentBlock]) {
        activatedMemories = blocks
    }

    /// Fase 3: el SelfModel vivo reemplaza al SelfView estático provisional.
    public func updateSelfView(_ view: ProvisionalSelfView) {
        selfView = view
    }
}
