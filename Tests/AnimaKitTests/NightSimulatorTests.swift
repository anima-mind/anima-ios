import Foundation
import Testing
@testable import AnimaKit

// Campo #12: "Simular una noche" (Ajustes → Mente) corre un ciclo en foreground.

@Suite("Campo — Simular una noche")
struct NightSimulatorTests {

    static let distill = [ProviderEvent].text("""
        [{"content":"Joshua vive en Bogota","kind":"semantic","importance":8},
         {"content":"Trabaja como arquitecto de plataformas","kind":"semantic","importance":8}]
        """)
    static let reflection = [ProviderEvent].text(#"{"summary":"El dueno vive en Bogota","insights":[]}"#)

    static func consolidator(_ provider: Provider) throws -> (Consolidator, ConsolidationInbox) {
        let queue = try AnimaDatabase.temporary()
        let brain = Brain(queue: queue, embedder: Embedder(forceFallback: true))
        let consolidator = Consolidator(brain: brain, queue: queue, provider: provider,
                                        router: try .haikuAll(), authMode: .apiKey, token: "sk-ant-api03-x")
        return (consolidator, ConsolidationInbox(queue: queue))
    }

    @Test func cicloConDestiladoFijoReportaElResumen() async throws {
        let (consolidator, inbox) = try Self.consolidator(ScriptedProvider([Self.distill, Self.reflection]))
        try inbox.enqueue(sessionId: "s1", text: "Vivo en Bogota y trabajo como arquitecto de plataformas.")
        let goals = Locked(0)
        let sim = NightSimulator(consolidator: consolidator, goalCount: {
            goals.mutate { $0 += 1 }   // 0 antes, 1 después → 1 meta nueva
            return goals.value - 1
        })
        #expect(await sim.run() == "ciclo #1 — 2 memorias nuevas, 1 meta")
    }

    @Test func sinCandidatosNadaNuevo() async throws {
        let (consolidator, _) = try Self.consolidator(ScriptedProvider([Self.reflection]))
        let summary = try #require(await NightSimulator(consolidator: consolidator).run())
        #expect(summary.hasSuffix(NightSimulator.nothingNew))
    }

    @Test func resumenEnSingularYPlural() {
        func report(added: Int) -> Consolidator.CycleReport {
            .init(cycle: 3, distilled: added, added: added, updated: 0, invalidated: 0, noop: 0,
                  reconsolidated: 0, reflectionSummary: "", completed: true)
        }
        #expect(NightSimulator.summary(report(added: 1), newGoals: 2) == "ciclo #3 — 1 memoria nueva, 2 metas")
        #expect(NightSimulator.summary(report(added: 0), newGoals: 1) == "ciclo #3 — 0 memorias nuevas, 1 meta")
    }
}

#if canImport(SwiftUI)
@MainActor
@Suite struct SettingsSimulateNightTests {
    @Test func laFilaCorreElCicloYAvisaParaRefrescar() async throws {
        let (consolidator, inbox) = try NightSimulatorTests.consolidator(
            ScriptedProvider([NightSimulatorTests.distill, NightSimulatorTests.reflection]))
        try inbox.enqueue(sessionId: "s1", text: "Vivo en Bogota.")
        let ud = try #require(UserDefaults(suiteName: "test.night.\(UUID().uuidString)"))
        let model = SettingsViewModel(keychain: ProviderTokenStore(service: "svc", backend: InMemoryKeychain()),
                                      telemetry: Telemetry(queue: try AnimaDatabase.temporary()),
                                      onboardingDefaults: OnboardingDefaults(defaults: ud), availability: { .available })
        await model.simulateNight()   // sin simulador cableado: nada
        #expect(model.nightSummary == nil)
        model.nightSimulator = NightSimulator(consolidator: consolidator)
        var refreshed = 0
        model.onNightSimulated = { refreshed += 1 }
        await model.simulateNight()
        #expect(model.nightSummary?.hasPrefix("ciclo #1 — 2 memorias nuevas") == true)
        #expect(!model.simulatingNight)
        #expect(refreshed == 1)
    }
}
#endif
