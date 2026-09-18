import Foundation
import Testing
import GRDB
@testable import AnimaKit

@Suite struct ConsolidatorGoalsTests {

    private struct Rig {
        let queue: DatabaseQueue
        let brain: Brain
        let inbox: ConsolidationInbox
        let other: OtherModel
        func consolidator(_ provider: Provider) throws -> Consolidator {
            Consolidator(brain: brain, queue: queue, provider: provider,
                         router: try .haikuAll(), authMode: .apiKey, token: "sk-ant-api03-x",
                         otherModel: other)
        }
    }

    private func makeRig() throws -> Rig {
        let queue = try AnimaDatabase.temporary()
        return Rig(queue: queue,
                   brain: Brain(queue: queue, embedder: Embedder(forceFallback: true)),
                   inbox: ConsolidationInbox(queue: queue),
                   other: OtherModel(queue: queue))
    }

    // Sin hechos que destilar: el ciclo llama distill (→ []) y luego la etapa de
    // extracción de metas. Sin memorias nuevas, reflection no llama al modelo.
    private static let noFacts = [ProviderEvent].text("[]")
    private static let statedGoal = [ProviderEvent].text("""
        [{"statement":"Joshua quiere entrenar 3x por semana","evidence":"quiero entrenar 3x",
          "priority":7,"predicate":{"kind":"workouts_per_week","value":3}}]
        """)

    // MARK: - Etapa nueva del ciclo: extracción de Stated Goals

    @Test func cycleExtractsStatedGoalFromOwnerMessages() async throws {
        let rig = try makeRig()
        try rig.inbox.enqueue(sessionId: "s1", text: "Quiero entrenar 3 veces por semana desde este mes.")
        let provider = ScriptedProvider([Self.noFacts, Self.statedGoal])
        let consolidator = try rig.consolidator(provider)

        let report = try await consolidator.cycle()
        #expect(report.completed)

        let goals = await rig.other.allGoals()
        #expect(goals.contains { $0.source == .stated && $0.statement.contains("entrenar") })
        // Un goal stated motiva de inmediato (aparece en el deseo vigente).
        #expect(await rig.other.desire().contains { $0.source == .stated })
    }

    // MARK: - El ciclo es reanudable con la etapa nueva incluida

    @Test func cycleResumesThroughGoalsStage() async throws {
        let rig = try makeRig()
        try rig.inbox.enqueue(sessionId: "s1", text: "Mi meta es entrenar 3x por semana.")
        let provider = ScriptedProvider([Self.noFacts, Self.statedGoal])
        let consolidator = try rig.consolidator(provider)

        // Corta tras el reflection: la extracción de metas aún no corrió.
        let partial = try await consolidator.cycle(interrupting: { $0 == "reflected" })
        #expect(!partial.completed)
        #expect(await rig.other.allGoals().isEmpty)

        // Retoma: restructure (noop) → goals → done.
        let done = try await consolidator.cycle()
        #expect(done.completed)
        #expect(await rig.other.allGoals().contains { $0.source == .stated })
    }
}
