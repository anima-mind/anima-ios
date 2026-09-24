// ContextProfile.swift — la presión de WorkingMemory es RELATIVA al provider
// activo (§4.9 implicación 2): ~4k tokens del modelo local vs 200k+ de Claude.
// El perfil fija el presupuesto, la ventana de history, cuántas memorias
// activadas entran y CÓMO se alivia la presión.

import Foundation

public struct ContextProfile: Sendable, Equatable {
    public enum ReliefMode: Sendable, Equatable {
        /// Claude: betas context-management / compaction (server-side, §5.1).
        case serverSide
        /// On-device: solo mecánico local — trim de tool results viejos +
        /// history window agresiva + evict al Brain. Jamás betas de Anthropic.
        case localMechanical
    }

    /// Presupuesto de contexto del modelo (tokens) — denominador de la presión.
    public var contextBudgetTokens: Int
    /// Tope de la history window en el ensamblado (`Int.max` = sin tope).
    public var historyBudgetTokens: Int
    /// Máximo de memorias activadas que entran al bloque etiquetado.
    public var maxActivatedMemories: Int
    public var reliefMode: ReliefMode

    public init(contextBudgetTokens: Int, historyBudgetTokens: Int,
                maxActivatedMemories: Int, reliefMode: ReliefMode) {
        self.contextBudgetTokens = contextBudgetTokens
        self.historyBudgetTokens = historyBudgetTokens
        self.maxActivatedMemories = maxActivatedMemories
        self.reliefMode = reliefMode
    }

    /// Claude (Opus/Haiku): el comportamiento previo, sin cambios.
    public static let claude = ContextProfile(
        contextBudgetTokens: 180_000, historyBudgetTokens: .max,
        maxActivatedMemories: 8, reliefMode: .serverSide)

    /// Apple Foundation Models (~4096 tokens, respuesta incluida): la history
    /// cabe en ~1k tokens y solo entran las 3 memorias más relevantes, para dejar
    /// sitio a instructions + tools + la respuesta.
    public static let onDevice = ContextProfile(
        contextBudgetTokens: 4096, historyBudgetTokens: 1000,
        maxActivatedMemories: 3, reliefMode: .localMechanical)
}

// MARK: - Relieve mecánico local (on-device)

/// Funciones puras del relieve local. Nada sale del teléfono y no hay llamada
/// extra al modelo: se recorta texto que ya vive en el transcript canónico y
/// lo desalojado se encola al Brain (vía ConsolidationInbox) — se pierde el
/// texto, no el insight.
public enum LocalRelief {
    public static let trimmedPlaceholder = "[resultado anterior recortado para liberar contexto]"
    /// Presión desde la que se alivia antes de cada llamada.
    public static let threshold = 0.7
    /// Objetivo tras aliviar (fracción del presupuesto).
    public static let target = 0.5

    public struct Result: Sendable, Equatable {
        public var messages: [Message]
        public var evicted: [Message]
        public var didRelieve: Bool
    }

    public static func estimateTokens(_ messages: [Message]) -> Int {
        let chars = messages.reduce(0) { acc, message in
            acc + message.content.reduce(0) { $0 + SymbolicStore.approxChars($1) }
        }
        return Int(Double(chars) / 3.6)
    }

    /// Reemplaza el contenido de los tool results viejos (todos menos los
    /// últimos `keepLast`) por un placeholder. Son re-obtenibles re-llamando la tool.
    public static func trimStaleToolResults(_ messages: [Message], keepLast: Int = 1) -> [Message] {
        var seen = 0
        var out = messages
        for i in out.indices.reversed() {
            for j in out[i].content.indices.reversed() {
                guard case .toolResult(let id, let content, let isError) = out[i].content[j] else { continue }
                seen += 1
                if seen > keepLast, content != trimmedPlaceholder {
                    out[i].content[j] = .toolResult(toolUseId: id, content: trimmedPlaceholder, isError: isError)
                }
            }
        }
        return out
    }

    /// Desaloja history vieja (desde el frente) hasta bajar de `targetTokens`,
    /// protegiendo la cola volátil del turno: del primer `role:system` (self,
    /// banner, memorias, turn input y el tool loop en curso) al final.
    public static func shrinkHistory(_ messages: [Message], targetTokens: Int) -> (kept: [Message], evicted: [Message]) {
        let tailStart = messages.firstIndex { $0.role == .system }
            ?? messages.lastIndex { $0.role == .user } ?? messages.count
        var kept = messages
        var evicted: [Message] = []
        var protectedFrom = tailStart
        while estimateTokens(kept) > targetTokens, protectedFrom > 0 {
            evicted.append(kept.removeFirst())
            protectedFrom -= 1
        }
        // Un tool_result huérfano (su tool_use fue desalojado) no puede abrir la ventana.
        while protectedFrom > 0, let first = kept.first, first.role == .user,
              first.content.allSatisfy({ if case .toolResult = $0 { return true } else { return false } }) {
            evicted.append(kept.removeFirst())
            protectedFrom -= 1
        }
        return (kept, evicted)
    }

    /// La escalera local: 1) trim de tool results viejos; 2) si no alcanza,
    /// history window más corta con evict. `force` (tras un overflow real) alivia
    /// aunque la estimación diga que cabe — la estimación subestima tools/instructions.
    public static func apply(_ messages: [Message], budgetTokens: Int, force: Bool = false) -> Result {
        let budget = Double(max(1, budgetTokens))
        let pressure = Double(estimateTokens(messages)) / budget
        guard force || pressure > threshold else {
            return Result(messages: messages, evicted: [], didRelieve: false)
        }
        // Tras un overflow real la estimación ya "cabía": el objetivo baja a la
        // mitad de lo actual para que el reintento sea de verdad más corto.
        let targetTokens = force
            ? min(Int(budget * target / 2), estimateTokens(messages) / 2)
            : Int(budget * target)
        let trimmed = trimStaleToolResults(messages)
        guard force || estimateTokens(trimmed) > targetTokens else {
            return Result(messages: trimmed, evicted: [], didRelieve: true)
        }
        let (kept, evicted) = shrinkHistory(trimmed, targetTokens: targetTokens)
        return Result(messages: kept, evicted: evicted, didRelieve: true)
    }
}
