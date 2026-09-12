import Testing
@testable import AnimaKit

@Suite struct PlasticityTests {
    @Test func newbornIsFullyPlastic() {
        #expect(Plasticity.value(cycles: 0) == 1.0)
    }

    @Test func decreasesMonotonically() {
        var prev = Plasticity.value(cycles: 0)
        for n in 1...100 {
            let p = Plasticity.value(cycles: n)
            #expect(p < prev)
            prev = p
        }
    }

    @Test func floorsAtPMin() {
        #expect(Plasticity.value(cycles: 10_000) >= Plasticity.pMin)
        #expect(abs(Plasticity.value(cycles: 10_000) - Plasticity.pMin) < 1e-8)
    }

    // Valores canónicos cross-runtime: animad (Go) asserta EXACTAMENTE estos.
    @Test func canonicalCrossRuntimeValues() {
        #expect(abs(Plasticity.value(cycles: 10) - 0.7307047450) < 1e-8)
        #expect(abs(Plasticity.value(cycles: 30) - 0.3994854691) < 1e-8)
        #expect(abs(Plasticity.value(cycles: 90) - 0.0972977149) < 1e-8)
    }

    @Test func regimes() {
        #expect(Plasticity.regime(cycles: 0) == .bootstrap)
        #expect(Plasticity.regime(cycles: 20) == .adolescence)
        #expect(Plasticity.regime(cycles: 90) == .maturity)
    }
}
