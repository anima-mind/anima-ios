import Foundation
import Testing
import GRDB
@testable import AnimaKit

@Suite struct ConsolidatorTests {

    private struct Rig {
        let queue: DatabaseQueue
        let brain: Brain
        let inbox: ConsolidationInbox
        func consolidator(_ provider: Provider) throws -> Consolidator {
            Consolidator(brain: brain, queue: queue, provider: provider,
                         router: try .haikuAll(), authMode: .apiKey, token: "sk-ant-api03-x")
        }
    }

    private func makeRig() throws -> Rig {
        let queue = try AnimaDatabase.temporary()
        return Rig(queue: queue,
                   brain: Brain(queue: queue, embedder: Embedder(forceFallback: true)),
                   inbox: ConsolidationInbox(queue: queue))
    }

    private static let distillTwoFacts = [ProviderEvent].text("""
        [{"content":"Joshua vive en Bogota","kind":"semantic","importance":8},
         {"content":"Trabaja como arquitecto de plataformas","kind":"semantic","importance":8}]
        """)
    private static let reflection = [ProviderEvent].text(#"{"summary":"El dueno vive en Bogota y es arquitecto","insights":[]}"#)

    // MARK: - Ciclo end-to-end: candidatos → memorias

    @Test func fullCycleTurnsCandidatesIntoMemories() async throws {
        let rig = try makeRig()
        try rig.inbox.enqueue(sessionId: "s1", text: "Vivo en Bogota y trabajo como arquitecto de plataformas.")
        let provider = ScriptedProvider([Self.distillTwoFacts, Self.reflection])
        let consolidator = try rig.consolidator(provider)

        let report = try await consolidator.cycle()
        #expect(report.completed)
        #expect(report.added == 2)

        // Lo aprendido esta en el brain sin haber estado en el historial del turno.
        let memories = try await rig.brain.browse()
        #expect(memories.count >= 2)
        let activated = try await rig.brain.retrieve(MemoryQuery(text: "donde vive Joshua", turnRef: "t"))
        #expect(activated.contains { $0.content.contains("Bogota") })
        // El inbox quedo consolidado.
        #expect(try rig.inbox.pendingCount() == 0)
    }

    // MARK: - Reanudable: matar tras la etapa b (distilled) retoma en c

    @Test func cycleResumesAfterDistilledStage() async throws {
        let rig = try makeRig()
        try rig.inbox.enqueue(sessionId: "s1", text: "Vivo en Bogota y trabajo como arquitecto de plataformas.")
        let provider = ScriptedProvider([Self.distillTwoFacts, Self.reflection])
        let consolidator = try rig.consolidator(provider)

        // Corta justo despues del destilado.
        let partial = try await consolidator.cycle(interrupting: { $0 == "distilled" })
        #expect(!partial.completed)
        // Destilado persistido, pero aun sin memorias escritas.
        let distilledRows = try await rig.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cycle_distilled") ?? 0
        }
        #expect(distilledRows == 2)
        #expect(try await rig.brain.browse().isEmpty)

        // Retoma donde iba: escribe y reflexiona.
        let done = try await consolidator.cycle()
        #expect(done.completed)
        #expect(try await rig.brain.browse().count >= 2)
    }

    // MARK: - Eval #3 (staleness): correccion explicita invalida la memoria

    @Test func explicitCorrectionInvalidatesContradictedMemory() async throws {
        let rig = try makeRig()
        // Memoria previa (como si viniera de un ciclo anterior).
        let bogota = try await rig.brain.add(MemoryCandidate(content: "Joshua vive en Bogota", importance: 8), cycle: 0)

        try rig.inbox.enqueue(sessionId: "s1", text: "Correccion: ya no vivo en Bogota.")
        let distill = [ProviderEvent].text(#"[{"content":"Joshua ya no vive en Bogota","kind":"semantic","importance":8}]"#)
        let decision = [ProviderEvent].text(#"{"decision":"INVALIDATE","target_id":"\#(bogota)","reason":"El dueno indico explicitamente que ya no vive en Bogota"}"#)
        let provider = ScriptedProvider([distill, decision, Self.reflection])
        let consolidator = try rig.consolidator(provider)

        let report = try await consolidator.cycle()
        #expect(report.completed)
        #expect(report.invalidated == 1)

        let record = try #require(try await rig.brain.record(bogota))
        #expect(!record.isValid)
        #expect(record.invalidationReason?.contains("Bogota") == true)
        // Invalidada no se recupera, pero persiste con razon (bi-temporal).
        let activated = try await rig.brain.retrieve(MemoryQuery(text: "donde vive Joshua", turnRef: "t"))
        #expect(!activated.contains { $0.id == bogota })
        #expect(try await rig.brain.browse().contains { $0.id == bogota })
    }

    // MARK: - Reconsolidacion: la memoria frecuente se re-evalua

    @Test func frequentlyUsedMemoryIsReconsolidated() async throws {
        let rig = try makeRig()
        let id = try await rig.brain.add(MemoryCandidate(content: "Joshua prefiere reuniones en la manana", importance: 6), cycle: 0)
        // Simula recuperaciones frecuentes desde el ultimo ciclo.
        try await rig.brain.usageLog(memoryId: id, sessionId: "s1", outcome: .neutral)
        try await rig.brain.usageLog(memoryId: id, sessionId: "s2", outcome: .neutral)

        let revision = [ProviderEvent].text(#"{"action":"revise","content":"Joshua prefiere reuniones temprano, entre 8 y 10 am","importance":7,"reason":"recuperada con frecuencia; se precisa el rango"}"#)
        let provider = ScriptedProvider([revision, Self.reflection])
        let consolidator = try rig.consolidator(provider)

        let report = try await consolidator.cycle()
        #expect(report.completed)
        #expect(report.reconsolidated >= 1)

        let old = try #require(try await rig.brain.record(id))
        #expect(!old.isValid)
        // Existe una fila nueva que revisa la vieja.
        let revised = try await rig.brain.browse().first { $0.revisesId == id }
        #expect(revised != nil)
        #expect(revised?.content.contains("temprano") == true)
    }
}
