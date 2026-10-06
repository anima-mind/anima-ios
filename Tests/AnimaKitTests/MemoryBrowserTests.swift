import Foundation
import Testing
@testable import AnimaKit

// Batch 5b #10: memoria legible — origen, tipo y confianza en español; solo
// activas por defecto; invalidar con razón opcional; vaciar invalidadas.

@MainActor
@Suite struct MemoryBrowserTests {
    @Test func activeByDefaultWithReadableOriginAndPurge() async throws {
        let queue = try AnimaDatabase.temporary()
        let brain = Brain(queue: queue)
        let distilled = try await brain.add(MemoryCandidate(content: "Le gusta correr temprano", source: "cycle:3"), cycle: 3)
        _ = try await brain.add(MemoryCandidate(content: "Aprendí a preguntar antes", kind: .reflection), cycle: 3)
        let chat = try await brain.add(MemoryCandidate(content: "Vive en Medellín", source: "turn"))
        let unknown = try await brain.add(MemoryCandidate(content: "eco viejo"))
        try await brain.invalidate(id: unknown, reason: "eco/meta (v2)")

        let model = MemoryBrowserViewModel(brain: brain)
        await model.load()
        #expect(model.active.count == 3 && model.invalidated.count == 1)
        #expect(!model.showInvalidated)
        #expect(Set(model.active.map(\.origin)) == ["Noche #3 · destilado", "Noche #3 · reflexión", "Chat"])
        #expect(model.invalidated.first?.origin == "origen desconocido")

        await model.invalidate(chat)
        #expect(model.invalidated.contains { $0.id == chat && $0.invalidationReason == MemoryBrowserViewModel.defaultReason })
        await model.invalidate(distilled, reason: "  ya no corre  ")
        #expect(model.invalidated.contains { $0.id == distilled && $0.invalidationReason == "ya no corre" })

        await model.openDetail(model.active[0].id)
        #expect(model.selected?.origin == "Noche #3 · reflexión")
        await model.openDetail("no-existe")
        #expect(model.selected?.content == "")

        model.showInvalidated = true
        await model.purgeInvalidated()
        #expect(model.invalidated.isEmpty && model.active.count == 1 && !model.showInvalidated)
        #expect(try await brain.purgeInvalidated() == 0)                // idempotente; activas intactas
        #expect(try await brain.browse().count == 1)
        let raw = try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory") }
        #expect(raw == 4)                                                 // bi-temporal: siguen en la base
    }

    @Test func spanishLabels() {
        #expect(MemoryBrowserViewModel.kindLabel(.semantic) == "semántica")
        #expect(MemoryBrowserViewModel.kindLabel(.episodic) == "episódica")
        #expect(MemoryBrowserViewModel.kindLabel(.procedural) == "procedimental")
        #expect(MemoryBrowserViewModel.kindLabel(.lesson) == "lección")
        #expect(MemoryBrowserViewModel.confidenceLabel(0.8) == "confianza 80 %")
    }
}
