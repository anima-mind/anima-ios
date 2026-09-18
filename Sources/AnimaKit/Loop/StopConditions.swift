// StopConditions.swift — condiciones de parada del tool loop (§4.4, §5.10):
// maxIterations, cancelación cooperativa y presupuesto de tokens por sesión.

import Foundation

public struct StopConditions: Sendable {
    public var maxIterations: Int
    public var tokenBudget: Int   // tope de tokens (input+output) por turno completo

    public init(maxIterations: Int = 10, tokenBudget: Int = 500_000) {
        self.maxIterations = maxIterations
        self.tokenBudget = tokenBudget
    }

    public enum Stop: Sendable, Equatable {
        case none
        case maxIterations
        case cancelled
        case budgetExceeded
    }

    /// Evalúa si el loop debe detenerse. `iteration` es 1-based.
    public func evaluate(iteration: Int, tokensUsed: Int, isCancelled: Bool) -> Stop {
        if isCancelled { return .cancelled }
        if iteration > maxIterations { return .maxIterations }
        if tokensUsed >= tokenBudget { return .budgetExceeded }
        return .none
    }
}
