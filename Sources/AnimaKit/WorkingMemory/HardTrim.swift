// HardTrim.swift — el último recurso para que NUNCA haya un turno imposible
// (batch 5b #4: cambiar a Claude → modelo de Apple a mitad de conversación
// dejaba un contexto que no cabía y "Reintentar" repetía el error). Cero LLM,
// determinista: se conservan los system (base, SelfView, reloj…), el turno del
// dueño y el tool loop en curso; las memorias activadas se sueltan si estorban;
// de la history entran los turnos más recientes que quepan. Si aun así no cabe,
// se acorta el texto más largo de la cola (nunca se quita el turno del dueño).

import Foundation

public enum HardTrim {
    public struct Result: Sendable, Equatable {
        public var messages: [Message]
        /// Cuántos mensajes de history (los más recientes) quedaron.
        public var keptHistory: Int
        public var droppedHistory: Int
        public var didTrim: Bool
    }

    public static let truncationMark = "…[recortado para caber en el modelo]"

    /// `availableTokens` = ventana del modelo − (system base + tools + respuesta).
    public static func apply(_ messages: [Message], availableTokens: Int) -> Result {
        let budget = max(64, availableTokens)
        let tailStart = messages.firstIndex { $0.role == .system }
            ?? messages.lastIndex { $0.role == .user } ?? messages.count
        let history = Array(messages[..<tailStart])
        var tail = Array(messages[tailStart...])
        guard LocalRelief.estimateTokens(messages) > budget else {
            return Result(messages: messages, keptHistory: history.count, droppedHistory: 0, didTrim: false)
        }
        // 1) Las memorias/skill activados son prescindibles frente al turno.
        if LocalRelief.estimateTokens(tail) > budget {
            tail.removeAll { isActivatedContext($0) }
        }
        // 2) Si la cola sola no cabe: acortar su texto más largo hasta que quepa.
        var guardrail = 0
        while LocalRelief.estimateTokens(tail) > budget, guardrail < 32 {
            guardrail += 1
            guard shortenLongestText(&tail, overBy: LocalRelief.estimateTokens(tail) - budget) else { break }
        }
        // 3) History desde el final mientras quepa; jamás abre con un tool_result
        //    huérfano ni con el assistant de un tool_use sin su resultado.
        var kept: [Message] = []
        var used = LocalRelief.estimateTokens(tail)
        for message in history.reversed() {
            let size = LocalRelief.estimateTokens([message])
            guard used + size <= budget else { break }
            kept.insert(message, at: 0)
            used += size
        }
        while let first = kept.first, first.role != .user || isOnlyToolResults(first) {
            kept.removeFirst()
        }
        return Result(messages: kept + tail, keptHistory: kept.count, droppedHistory: history.count - kept.count,
                      didTrim: true)
    }

    static func isActivatedContext(_ message: Message) -> Bool {
        guard message.role == .user, case .text(let t)? = message.content.first else { return false }
        return t.hasPrefix(WorkingMemory.activatedMemoriesHeader) || t.hasPrefix("[SKILL")
    }

    static func isOnlyToolResults(_ message: Message) -> Bool {
        message.content.allSatisfy { if case .toolResult = $0 { return true } else { return false } }
    }

    /// Acorta el bloque de texto más largo de la cola (≥ lo que sobra, con margen).
    static func shortenLongestText(_ tail: inout [Message], overBy tokens: Int) -> Bool {
        var best: (Int, Int, Int)?   // (mensaje, bloque, largo)
        for (i, message) in tail.enumerated() {
            for (j, block) in message.content.enumerated() {
                if case .text(let t) = block, t.count > (best?.2 ?? 200) { best = (i, j, t.count) }
            }
        }
        guard let (i, j, length) = best, case .text(let text) = tail[i].content[j] else { return false }
        let cut = min(length - 200, Int(Double(tokens) * 3.6 * 1.2) + truncationMark.count)
        guard cut > 0 else { return false }
        tail[i].content[j] = .text(String(text.prefix(length - cut)) + truncationMark)
        return true
    }
}

/// Qué tan lleno está el contexto del modelo activo (el medidor del chat).
public struct ContextGauge: Sendable, Equatable {
    public enum Level: Sendable, Equatable {
        case normal, high, critical
    }

    public var model: String
    public var budgetTokens: Int
    /// System base + instrucciones + herramientas.
    public var systemTokens: Int
    public var memoryTokens: Int
    public var conversationTokens: Int

    public init(model: String, budgetTokens: Int, systemTokens: Int, memoryTokens: Int, conversationTokens: Int) {
        self.model = model
        self.budgetTokens = budgetTokens
        self.systemTokens = systemTokens
        self.memoryTokens = memoryTokens
        self.conversationTokens = conversationTokens
    }

    public var usedTokens: Int { systemTokens + memoryTokens + conversationTokens }

    public var fraction: Double {
        guard budgetTokens > 0 else { return 0 }
        return min(1, Double(usedTokens) / Double(budgetTokens))
    }

    public var percent: Int { Int((fraction * 100).rounded()) }

    public var level: Level {
        switch fraction {
        case ..<0.7: return .normal
        case ..<0.9: return .high
        default: return .critical
        }
    }

    /// "2.1k de 4.1k tokens".
    public var summary: String { "\(Self.compact(usedTokens)) de \(Self.compact(budgetTokens)) tokens" }

    public static func compact(_ tokens: Int) -> String {
        tokens < 1000 ? "\(tokens)" : String(format: "%.1fk", Double(tokens) / 1000).replacingOccurrences(of: ".0k", with: "k")
    }

    /// Mide un ensamblado: system (base + tools + role:system), memorias activadas
    /// y el resto (la conversación).
    public static func measure(_ messages: [Message], systemBase: String, tools: [ToolSpec], model: String,
                               budgetTokens: Int) -> ContextGauge {
        let fixed = fixedTokens(systemBase: systemBase, tools: tools)
        let system = LocalRelief.estimateTokens(messages.filter { $0.role == .system })
        let memories = LocalRelief.estimateTokens(messages.filter(HardTrim.isActivatedContext))
        let conversation = LocalRelief.estimateTokens(messages.filter { $0.role != .system && !HardTrim.isActivatedContext($0) })
        return ContextGauge(model: model, budgetTokens: budgetTokens, systemTokens: fixed + system,
                            memoryTokens: memories, conversationTokens: conversation)
    }

    /// System base (prosa, chars/3.6) + schemas de tools (JSON, chars/4.2).
    public static func fixedTokens(systemBase: String, tools: [ToolSpec]) -> Int {
        Int(Double(systemBase.count) / 3.6 + Double(toolChars(tools)) / 4.2)
    }

    public static func toolChars(_ tools: [ToolSpec]) -> Int {
        tools.reduce(0) { total, spec in
            switch spec {
            case .client(let name, let description, let schema):
                let json = (try? JSONEncoder().encode(schema)).map { $0.count } ?? 0
                return total + name.count + description.count + json
            default:
                return total + 200
            }
        }
    }
}

/// Lo que cabe del ensamblado en el modelo activo: ventana − (system base +
/// tools + respuesta reservada).
public struct ContextFit: Sendable {
    public var profile: ContextProfile
    public var systemBase: String
    public var tools: [ToolSpec]
    public var route: ModelRoute

    public init(profile: ContextProfile, systemBase: String, tools: [ToolSpec], route: ModelRoute) {
        self.profile = profile
        self.systemBase = systemBase
        self.tools = tools
        self.route = route
    }

    public var modelName: String { ModelNames.friendly(route.model) }

    public var reservedTokens: Int {
        ContextGauge.fixedTokens(systemBase: systemBase, tools: tools)
            + min(route.maxTokens, profile.contextBudgetTokens / 4)
    }

    /// Piso: el turno del dueño y algo de history siempre caben en la estimación
    /// (la heurística sobreestima los schemas; el overflow real lo cubre el loop).
    public static let minAvailableTokens = 512

    public var availableTokens: Int { max(Self.minAvailableTokens, profile.contextBudgetTokens - reservedTokens) }

    public func gauge(_ messages: [Message]) -> ContextGauge {
        ContextGauge.measure(messages, systemBase: systemBase, tools: tools, model: modelName,
                             budgetTokens: profile.contextBudgetTokens)
    }
}
