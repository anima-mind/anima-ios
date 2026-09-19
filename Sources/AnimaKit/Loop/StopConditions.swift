// StopConditions.swift — condiciones de parada del tool loop (§4.4, §5.10):
// maxIterations, cancelación cooperativa, presupuesto de tokens por turno,
// presupuesto de latencia del turno y detección de loop (misma tool + mismo
// input N veces seguidas).

import Foundation

public struct StopConditions: Sendable {
    public var maxIterations: Int
    public var tokenBudget: Int          // tope de tokens (input+output) por turno
    public var turnLatencyBudget: TimeInterval   // tope de reloj de pared por turno
    public var loopRepeatThreshold: Int  // misma tool+input N veces → detener

    public init(maxIterations: Int = 10,
                tokenBudget: Int = 500_000,
                turnLatencyBudget: TimeInterval = 300,
                loopRepeatThreshold: Int = 3) {
        self.maxIterations = maxIterations
        self.tokenBudget = tokenBudget
        self.turnLatencyBudget = turnLatencyBudget
        self.loopRepeatThreshold = loopRepeatThreshold
    }

    public enum Stop: Sendable, Equatable {
        case none
        case maxIterations
        case cancelled
        case budgetExceeded
        case latencyExceeded
        case loopDetected
    }

    /// Evalúa si el loop debe detenerse. `iteration` es 1-based; `elapsed` es el
    /// tiempo transcurrido del turno.
    public func evaluate(iteration: Int, tokensUsed: Int, elapsed: TimeInterval, isCancelled: Bool) -> Stop {
        if isCancelled { return .cancelled }
        if iteration > maxIterations { return .maxIterations }
        if tokensUsed >= tokenBudget { return .budgetExceeded }
        if elapsed >= turnLatencyBudget { return .latencyExceeded }
        return .none
    }
}

/// Detección de loop: misma tool + mismo input `threshold` veces consecutivas.
/// El input se canonicaliza con claves ordenadas para que el hash sea estable.
public struct LoopDetector: Sendable {
    public let threshold: Int
    private var lastKey: String?
    private var streak = 0

    public init(threshold: Int = 3) {
        self.threshold = threshold
    }

    /// Registra una tool call. Devuelve `true` cuando se alcanza el umbral de
    /// repeticiones consecutivas idénticas.
    public mutating func record(tool: String, input: JSONValue) -> Bool {
        let key = tool + "|" + Self.canonical(input)
        if key == lastKey {
            streak += 1
        } else {
            lastKey = key
            streak = 1
        }
        return streak >= threshold
    }

    static func canonical(_ input: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(input), let string = String(data: data, encoding: .utf8) else {
            return "?"
        }
        return string
    }
}
