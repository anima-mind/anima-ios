import Foundation
import Testing
@testable import AnimaKit

@Suite struct BrainTests {

    private func makeBrain() throws -> Brain {
        Brain(queue: try AnimaDatabase.temporary(), embedder: Embedder(forceFallback: true))
    }

    // MARK: - Los 4 caminos de escritura

    @Test func writeAddCreatesLiveMemory() async throws {
        let brain = try makeBrain()
        let decision = try await brain.write(.add(MemoryCandidate(content: "Joshua vive en Bogota", importance: 8)))
        guard case .added(let id) = decision else { Issue.record("esperaba .added"); return }
        let record = try #require(try await brain.record(id))
        #expect(record.isValid)
        #expect(record.content == "Joshua vive en Bogota")
    }

    @Test func writeUpdateInvalidatesOldAndChainsNew() async throws {
        let brain = try makeBrain()
        guard case .added(let old) = try await brain.write(.add(MemoryCandidate(content: "Joshua vive en Bogota"))) else {
            Issue.record("setup"); return
        }
        let decision = try await brain.write(.update(old, MemoryCandidate(content: "Joshua vive en Medellin"),
                                                     reason: "se mudo"))
        guard case .updated(let new, let previous) = decision else { Issue.record("esperaba .updated"); return }
        #expect(previous == old)
        let oldRecord = try #require(try await brain.record(old))
        let newRecord = try #require(try await brain.record(new))
        #expect(!oldRecord.isValid)
        #expect(oldRecord.invalidationReason == "se mudo")
        #expect(newRecord.isValid)
        #expect(newRecord.revisesId == old)
    }

    @Test func writeInvalidateMarksWithReason() async throws {
        let brain = try makeBrain()
        guard case .added(let id) = try await brain.write(.add(MemoryCandidate(content: "Joshua toma cafe todas las mananas"))) else {
            Issue.record("setup"); return
        }
        let decision = try await brain.write(.invalidate(id, reason: "el dueno dejo el cafe"))
        guard case .invalidated(let target) = decision else { Issue.record("esperaba .invalidated"); return }
        #expect(target == id)
        let record = try #require(try await brain.record(id))
        #expect(!record.isValid)
        #expect(record.invalidatedAt != nil)
        #expect(record.invalidationReason == "el dueno dejo el cafe")
    }

    @Test func writeNoopChangesNothing() async throws {
        let brain = try makeBrain()
        _ = try await brain.write(.add(MemoryCandidate(content: "Joshua vive en Bogota")))
        let before = try await brain.browse().count
        let decision = try await brain.write(.noop)
        #expect(decision == .noop)
        #expect(try await brain.browse().count == before)
    }

    // MARK: - Bi-temporal: invalidada no se recupera pero sigue existiendo

    @Test func invalidatedMemoryIsNotRetrievedButPersists() async throws {
        let brain = try makeBrain()
        guard case .added(let id) = try await brain.write(.add(MemoryCandidate(content: "Joshua vive en Bogota"))) else {
            Issue.record("setup"); return
        }
        let before = try await brain.retrieve(MemoryQuery(text: "donde vive Joshua", turnRef: "t1"))
        #expect(before.contains { $0.content.contains("Bogota") })

        try await brain.invalidate(id: id, reason: "ya no vive alli")

        let after = try await brain.retrieve(MemoryQuery(text: "donde vive Joshua", turnRef: "t2"))
        #expect(!after.contains { $0.id == id })
        // Sigue existiendo con su razon visible (bi-temporal, jamas DELETE).
        let record = try #require(try await brain.record(id))
        #expect(!record.isValid)
        #expect(record.invalidationReason == "ya no vive alli")
        #expect(try await brain.browse().contains { $0.id == id })
    }

    // MARK: - FTS5 + coseno + RRF

    @Test func lexicalAndSemanticQueriesFindExpected() async throws {
        let brain = try makeBrain()
        _ = try await brain.write(.add(MemoryCandidate(content: "Joshua vive en Bogota")))
        _ = try await brain.write(.add(MemoryCandidate(content: "Joshua trabaja como arquitecto en La Haus")))
        guard case .added(let medellin) = try await brain.write(.add(MemoryCandidate(content: "El clima en Medellin es templado"))) else {
            Issue.record("setup"); return
        }
        // Query lexica: la palabra clave solo esta en una memoria.
        let byKeyword = try await brain.retrieve(MemoryQuery(text: "Medellin", turnRef: "t1"))
        #expect(byKeyword.first?.id == medellin)
    }

    @Test func rrfRanksTheDoublyMatchedMemoryFirst() async throws {
        let brain = try makeBrain()
        guard case .added(let bogota) = try await brain.write(.add(MemoryCandidate(content: "Joshua vive en Bogota"))) else {
            Issue.record("setup"); return
        }
        _ = try await brain.write(.add(MemoryCandidate(content: "Joshua disfruta el senderismo")))
        // "Joshua Bogota" pega fuerte (lexico + semantico) contra la primera.
        let results = try await brain.retrieve(MemoryQuery(text: "donde vive Joshua Bogota", turnRef: "t1"))
        #expect(results.first?.id == bogota)
    }

    // MARK: - usage_log

    @Test func retrieveFillsUsageLog() async throws {
        let queue = try AnimaDatabase.temporary()
        let brain = Brain(queue: queue, embedder: Embedder(forceFallback: true))
        _ = try await brain.write(.add(MemoryCandidate(content: "Joshua vive en Bogota")))
        _ = try await brain.write(.add(MemoryCandidate(content: "Joshua trabaja en La Haus")))
        let activated = try await brain.retrieve(MemoryQuery(text: "Joshua", turnRef: "turn-42"))
        #expect(!activated.isEmpty)
        let logged = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_log WHERE turn_ref='turn-42'") ?? 0
        }
        #expect(logged == activated.count)
    }
}
