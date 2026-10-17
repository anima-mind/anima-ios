import Foundation
import Testing
import GRDB
@testable import AnimaKit

// Campo 2026-10-16: "no hay forma de una memoria invalidada reanudarla" y
// "debería haber la opción de eliminar solo ese". Restaurar (sin reemplazo o
// reemplazando la versión vigente: nunca dos vigentes), historial del evento,
// la decisión del dueño gana al sueño, eliminar UNA invalidada y la migración v22.

@Suite struct MemoryRestoreTests {
    private func brain() throws -> (Brain, DatabaseQueue) {
        let queue = try AnimaDatabase.temporary()
        return (Brain(queue: queue, embedder: Embedder(forceFallback: true)), queue)
    }

    private func validIDs(_ chain: [MemoryRecord]) -> [MemoryID] {
        chain.filter(\.isValid).map(\.id)
    }

    @Test func restoreWithoutReplacementIsCurrentAndRetrievableAgain() async throws {
        let (b, _) = try brain()
        let id = try await b.add(MemoryCandidate(content: "Joshua toma café sin azúcar", importance: 7))
        try await b.invalidate(id: id, reason: "ya no toma café")
        let hidden = try await b.retrieve(MemoryQuery(text: "café sin azúcar", turnRef: "t0"))
        #expect(!hidden.contains { $0.id == id })

        let at = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try await b.restore(id: id, at: at) == .restored(id))

        let record = try #require(try await b.record(id))
        #expect(record.isValid && record.invalidationReason == nil)
        #expect(record.ownerRestoredAt == at)
        let chain = try await b.revisionChain(id)
        #expect(chain.map(\.id) == [id])
        #expect(chain[0].events == [MemoryEvent(kind: .ownerRestored, detail: "ya no toma café", at: at)])

        let found = try await b.retrieve(MemoryQuery(text: "café sin azúcar", turnRef: "t1"))
        #expect(found.contains { $0.id == id })
        #expect(try await b.similar(to: "Joshua toma café sin azúcar", threshold: 0.5).contains { $0.id == id })
    }

    @Test func restoreIsANoOpForCurrentPurgedOrMissing() async throws {
        let (b, _) = try brain()
        let current = try await b.add(MemoryCandidate(content: "vive en Medellín"))
        #expect(try await b.restore(id: current) == .unchanged)
        #expect(try await b.record(current)?.ownerRestoredAt == nil)
        #expect(try await b.revisionChain(current).first?.events.isEmpty == true)

        let purged = try await b.add(MemoryCandidate(content: "eco viejo"))
        try await b.invalidate(id: purged, reason: "eco")
        #expect(try await b.purge(id: purged))
        #expect(try await b.restore(id: purged) == .unchanged)
        #expect(try await b.record(purged)?.isValid == false)

        #expect(try await b.restore(id: "no-existe") == .unchanged)

        let twice = try await b.add(MemoryCandidate(content: "corre los domingos"))
        try await b.invalidate(id: twice, reason: "x")
        #expect(try await b.restore(id: twice) == .restored(twice))
        #expect(try await b.restore(id: twice) == .unchanged)
    }

    @Test func restoringAReplacedVersionLeavesExactlyOneCurrent() async throws {
        let (b, _) = try brain()
        let v1 = try await b.add(MemoryCandidate(content: "reuniones en la mañana", importance: 6))
        let v2 = try await b.reconsolidate(id: v1, revision: Revision(content: "reuniones de 8 a 10", importance: 7,
                                                                      reason: "se precisa el rango"))
        #expect(validIDs(try await b.revisionChain(v1)) == [v2])

        #expect(try await b.restore(id: v1) == .replaced(restored: v1, invalidated: [v2]))
        let chain = try await b.revisionChain(v2)
        #expect(chain.map(\.id) == [v1, v2])
        #expect(validIDs(chain) == [v1])
        #expect(chain[1].invalidationReason == Brain.ownerReplacedReason)
        #expect(chain[0].events.first?.detail == "se precisa el rango")
        let found = try await b.retrieve(MemoryQuery(text: "reuniones", turnRef: "t"))
        #expect(found.contains { $0.id == v1 } && !found.contains { $0.id == v2 })

        // Vuelve a la nueva: sigue habiendo UNA vigente.
        #expect(try await b.restore(id: v2) == .replaced(restored: v2, invalidated: [v1]))
        #expect(validIDs(try await b.revisionChain(v1)) == [v2])
        #expect(try await b.record(v1)?.invalidationReason == Brain.ownerReplacedReason)
    }

    @Test func chainIncludesBranchesAfterRestoringAnOldVersion() async throws {
        let (b, _) = try brain()
        let v1 = try await b.add(MemoryCandidate(content: "come a las 12"))
        let v2 = try await b.reconsolidate(id: v1, revision: Revision(content: "come a la 1", importance: 5, reason: "r"))
        _ = try await b.restore(id: v1)
        let v3 = try await b.reconsolidate(id: v1, revision: Revision(content: "come a las 12:30", importance: 5, reason: "r2"))
        for id in [v1, v2, v3] {
            let chain = try await b.revisionChain(id)
            #expect(chain.map(\.id) == [v1, v2, v3])
            #expect(validIDs(chain) == [v3])
        }
        #expect(try await b.restore(id: v2) == .replaced(restored: v2, invalidated: [v3]))
        #expect(validIDs(try await b.revisionChain(v1)) == [v2])
    }

    @Test func deleteOnlyThatInvalidatedKeepsTheOthersAndTheChain() async throws {
        let (b, queue) = try brain()
        let v1 = try await b.add(MemoryCandidate(content: "reuniones en la mañana"))
        let v2 = try await b.reconsolidate(id: v1, revision: Revision(content: "reuniones 8-10", importance: 6, reason: "a"))
        let v3 = try await b.reconsolidate(id: v2, revision: Revision(content: "reuniones 8-9", importance: 6, reason: "b"))
        let other = try await b.add(MemoryCandidate(content: "eco"))
        try await b.invalidate(id: other, reason: "eco")

        // Control negativo: una vigente no se elimina.
        #expect(!(try await b.purge(id: v3)))
        #expect(try await b.record(v3)?.isPurged == false)

        #expect(try await b.purge(id: v2))
        #expect(!(try await b.purge(id: v2)))
        let browse = try await b.browse()
        #expect(!browse.contains { $0.id == v2 })
        #expect(browse.contains { $0.id == v1 } && browse.contains { $0.id == other } && browse.contains { $0.id == v3 })
        // La cadena de la vigente sigue entera (v1 → v3 a través de la eliminada) y sin ella.
        #expect(try await b.revisionChain(v3).map(\.id) == [v1, v3])
        #expect(try await b.revisionChain(v1).map(\.id) == [v1, v3])
        let raw = try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory WHERE id=?", arguments: [v2]) }
        #expect(raw == 1)

        // "Vaciar invalidadas" sigue funcionando y no toca lo restaurado.
        _ = try await b.restore(id: v1)
        #expect(try await b.purgeInvalidated() == 2)
        #expect(try await b.record(v1)?.isPurged == false)
        #expect(try await b.record(v1)?.isValid == true)
    }

    // MARK: - Migración v22

    static func seededMemories(upTo migration: String) throws -> DatabaseQueue {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try AnimaDatabase.migrator().migrate(queue, upTo: migration)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO memory (id, kind, content, importance, source, created_at, event_at,
                                    invalidated_at, invalidation_reason, revises_id, consolidation_cycle)
                VALUES ('a', 'semantic', 'vive en Bogotá', 8, 'cycle:1', 100, NULL, 150, 'se mudó', NULL, 1),
                       ('b', 'semantic', 'vive en Medellín', 8, 'cycle:2', 150, NULL, NULL, NULL, 'a', 2)
                """)
        }
        return queue
    }

    @Test func v22IsAdditiveAndComesAfterV21() async throws {
        let ids = AnimaDatabase.migrator().migrations
        let v21 = try #require(ids.firstIndex(of: "v21-goal-lifecycle"))
        let v22 = try #require(ids.firstIndex(of: "v22-memory-owner-restore"))
        #expect(v22 == v21 + 1)

        let queue = try Self.seededMemories(upTo: "v21-goal-lifecycle")
        #expect(try await queue.read { try !$0.tableExists("memory_event") })
        try AnimaDatabase.migrator().migrate(queue)
        let rows = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, content, invalidated_at, revises_id, owner_restored_at FROM memory ORDER BY id")
        }
        #expect(rows.map { $0["content"] as String } == ["vive en Bogotá", "vive en Medellín"])
        #expect(rows.map { $0["invalidated_at"] as Double? } == [150, nil])
        #expect(rows.map { $0["revises_id"] as String? } == [nil, "a"])
        #expect(rows.allSatisfy { ($0["owner_restored_at"] as Double?) == nil })
        #expect(try await queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM memory_event") } == 0)

        let b = Brain(queue: queue, embedder: Embedder(forceFallback: true))
        #expect(try await b.restore(id: "a") == .replaced(restored: "a", invalidated: ["b"]))
        #expect(try await b.revisionChain("b").filter(\.isValid).map(\.id) == ["a"])
    }

    // MARK: - El sueño respeta la decisión del dueño

    private static let reflection = [ProviderEvent].text(#"{"summary":"","insights":[]}"#)

    private func consolidator(_ b: Brain, _ queue: DatabaseQueue, _ scripts: [[ProviderEvent]]) throws -> Consolidator {
        Consolidator(brain: b, queue: queue, provider: ScriptedProvider(scripts),
                     router: try .haikuAll(), authMode: .apiKey, token: "sk-ant-api03-x")
    }

    private func bogotaRestored(restoredAt: Date, inboxBefore: Bool) async throws
        -> (Brain, DatabaseQueue, MemoryID) {
        let (b, queue) = try brain()
        let bogota = try await b.add(MemoryCandidate(content: "Joshua vive en Bogota", importance: 8))
        let inbox = ConsolidationInbox(queue: queue)
        if inboxBefore { try inbox.enqueue(sessionId: "s1", text: "Correccion: ya no vivo en Bogota.") }
        try await b.invalidate(id: bogota, reason: "invalidada por el dueño")
        _ = try await b.restore(id: bogota, at: restoredAt)
        if !inboxBefore { try inbox.enqueue(sessionId: "s1", text: "Correccion: ya no vivo en Bogota.") }
        return (b, queue, bogota)
    }

    private static let distill = [ProviderEvent].text(#"[{"content":"Joshua ya no vive en Bogota","kind":"semantic","importance":8}]"#)

    @Test func dreamDoesNotReinvalidateWhatTheOwnerRestored() async throws {
        let (b, queue, bogota) = try await bogotaRestored(restoredAt: Date().addingTimeInterval(60), inboxBefore: true)
        let decision = [ProviderEvent].text(#"{"decision":"INVALIDATE","target_id":"\#(bogota)","reason":"contradicha"}"#)
        let report = try await consolidator(b, queue, [Self.distill, decision, Self.reflection]).cycle()
        #expect(report.completed)
        #expect(report.invalidated == 0 && report.noop == 1)
        #expect(try await b.record(bogota)?.isValid == true)
    }

    @Test func dreamDoesNotReviseWhatTheOwnerRestored() async throws {
        let (b, queue, bogota) = try await bogotaRestored(restoredAt: Date().addingTimeInterval(60), inboxBefore: true)
        let decision = [ProviderEvent].text(#"{"decision":"UPDATE","target_id":"\#(bogota)","reason":"refinada"}"#)
        let report = try await consolidator(b, queue, [Self.distill, decision, Self.reflection]).cycle()
        #expect(report.updated == 0)
        #expect(try await b.record(bogota)?.isValid == true)
        #expect(try await b.browse().first { $0.revisesId == bogota } == nil)
    }

    /// Control: evidencia nueva del dueño, posterior a la restauración, sí la invalida.
    @Test func newOwnerEvidenceAfterTheRestoreStillInvalidates() async throws {
        let (b, queue, bogota) = try await bogotaRestored(restoredAt: Date().addingTimeInterval(-60), inboxBefore: false)
        let decision = [ProviderEvent].text(#"{"decision":"INVALIDATE","target_id":"\#(bogota)","reason":"El dueño dijo que ya no vive en Bogota"}"#)
        let report = try await consolidator(b, queue, [Self.distill, decision, Self.reflection]).cycle()
        #expect(report.invalidated == 1)
        #expect(try await b.record(bogota)?.isValid == false)
    }

    @Test func reconsolidationSkipsRestoredButNotOthers() async throws {
        let (b, queue) = try brain()
        let restored = try await b.add(MemoryCandidate(content: "prefiere reuniones en la mañana", importance: 6))
        try await b.invalidate(id: restored, reason: "x")
        _ = try await b.restore(id: restored)
        for s in ["s1", "s2"] { try await b.usageLog(memoryId: restored, sessionId: s, outcome: .contradicted) }
        let revise = [ProviderEvent].text(#"{"action":"invalidate","reason":"contradicha en el uso"}"#)
        _ = try await consolidator(b, queue, [revise, Self.reflection]).cycle()
        #expect(try await b.record(restored)?.isValid == true)

        // Control: la misma señal sobre una memoria no restaurada sí la invalida.
        let plain = try await b.add(MemoryCandidate(content: "almuerza a las 2", importance: 6))
        for s in ["s3", "s4"] { try await b.usageLog(memoryId: plain, sessionId: s, outcome: .contradicted) }
        _ = try await consolidator(b, queue, [revise, Self.reflection]).cycle()
        #expect(try await b.record(plain)?.isValid == false)
        #expect(try await b.record(restored)?.isValid == true)
    }

    @Test func ownerCanInvalidateARestoredMemoryAgain() async throws {
        let (b, _) = try brain()
        let id = try await b.add(MemoryCandidate(content: "corre los martes"))
        try await b.invalidate(id: id, reason: "a")
        _ = try await b.restore(id: id)
        try await b.invalidate(id: id, reason: "invalidada por el dueño")
        #expect(try await b.record(id)?.isValid == false)
        #expect(try await b.revisionChain(id).first?.events.count == 1)
    }

    @Test func legacyCleanupSkipsRestored() async throws {
        let (b, queue) = try brain()
        let id = try await b.add(MemoryCandidate(content: "¿Qué hora es?"))
        try await b.invalidate(id: id, reason: "x")
        _ = try await b.restore(id: id)
        let invalidated = try await DistillMigration.runIfNeeded(queue: queue, brain: b, selfName: nil)
        #expect(invalidated == 0)
        #expect(try await b.record(id)?.isValid == true)
    }
}

@MainActor
@Suite struct MemoryBrowserRestoreTests {
    @Test func restoreAndDeleteFromTheBrowser() async throws {
        let queue = try AnimaDatabase.temporary()
        let brain = Brain(queue: queue, embedder: Embedder(forceFallback: true))
        let old = try await brain.add(MemoryCandidate(content: "Corre los martes", source: "cycle:2"), cycle: 2)
        let new = try await brain.reconsolidate(id: old, revision: Revision(content: "Corre martes y jueves",
                                                                           importance: 6, reason: "jueves"), cycle: 3)
        let lone = try await brain.add(MemoryCandidate(content: "eco", source: "turn"))
        try await brain.invalidate(id: lone, reason: "eco")

        let model = MemoryBrowserViewModel(brain: brain)
        await model.load()
        #expect(model.invalidated.first { $0.id == old }?.hasCurrentVersion == true)
        #expect(model.invalidated.first { $0.id == lone }?.hasCurrentVersion == false)

        await model.openDetail(old)
        #expect(model.selected?.hasCurrentVersion == true && model.selected?.isValid == false)
        await model.restore(old)
        #expect(model.selected?.id == old && model.selected?.isValid == true)
        #expect(model.selected?.chain.filter(\.isValid).map(\.id) == [old])
        let event = try #require(model.selected?.chain.first { $0.id == old }?.events.first)
        #expect(model.eventLine(event).hasPrefix("restaurada por el dueño · "))
        #expect(model.active.contains { $0.id == old } && model.invalidated.contains { $0.id == new })

        model.selected = nil
        await model.restore(lone)
        #expect(model.selected == nil)
        #expect(model.active.contains { $0.id == lone })

        try await brain.invalidate(id: lone, reason: "otra vez")
        await model.load()
        await model.openDetail(lone)
        await model.delete(lone)
        #expect(model.selected == nil)
        #expect(!model.items.contains { $0.id == lone })
        #expect(model.invalidated.map(\.id) == [new])
        await model.delete(old)
        #expect(model.active.contains { $0.id == old })
    }
}
