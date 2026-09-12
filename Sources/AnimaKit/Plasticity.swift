import Foundation

/// Plasticidad decreciente del SelfModel (spec §B.4, plan doc 04 §5.5).
/// Invariante cross-runtime (matriz C.1): misma fórmula y valores en animad (Go).
///
/// p(n) = p_min + (1 − p_min) · e^(−n/τ)
/// donde n = ciclos de consolidación exitosos (edad en experiencia, no wall-time).
public enum Plasticity {
    public static let pMin = 0.05
    public static let tauEdge = 30.0

    public static func value(cycles n: Int, tau: Double = tauEdge) -> Double {
        precondition(n >= 0, "cycles must be non-negative")
        return pMin + (1 - pMin) * exp(-Double(n) / tau)
    }

    /// Regímenes del período crítico (doc 04 §5.5).
    public enum Regime: Sendable, Equatable {
        case bootstrap      // p ≥ 0.7 — la mente se forma: identity/values/capabilities/style mutables
        case adolescence    // 0.3 ≤ p < 0.7 — solo capabilities y style
        case maturity       // p < 0.3 — identity/values requieren aprobación del Otro
    }

    public static func regime(cycles n: Int, tau: Double = tauEdge) -> Regime {
        let p = value(cycles: n, tau: tau)
        if p >= 0.7 { return .bootstrap }
        if p >= 0.3 { return .adolescence }
        return .maturity
    }
}
