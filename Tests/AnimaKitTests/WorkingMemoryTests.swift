import Foundation
import Testing
@testable import AnimaKit

@Suite struct WorkingMemoryTests {

    private func makeStore() throws -> (SymbolicStore, SessionID) {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let sid = try store.startSession()
        return (store, sid)
    }

    /// Golden test del orden estable §5.1: history -> mid-conversation system ->
    /// turn input. El system va DESPUÉS del history y ANTES del turno.
    @Test func assembleProducesStableOrder() async throws {
        let (store, sid) = try makeStore()
        try store.append(sessionId: sid, message: .user("hola"))
        try store.append(sessionId: sid, message: .assistant([.text("¿en qué te ayudo?")]))

        let wm = WorkingMemory(store: store)
        let messages = try await wm.assemble(.text("¿qué tengo mañana?", sessionId: sid))

        // Sin compaction: [user(history), assistant(history), system, user(turn)].
        #expect(messages.map(\.role) == [.user, .assistant, .system, .user])

        // El mid-conversation system es el render del SelfView provisional.
        #expect(messages[2].role == .system)
        #expect(messages[2].content == [.text(ProvisionalSelfView.provisional.render())])

        // Va después de todo el history y antes del turn input.
        let systemIndex = try #require(messages.firstIndex { $0.role == .system })
        let turnIndex = messages.count - 1
        #expect(systemIndex == turnIndex - 1)
        #expect(messages.last?.content == [.text("¿qué tengo mañana?")])
    }

    /// Los bloques compaction se re-anexan al frente cada turno (contrato beta).
    @Test func compactionBlocksAreReAppended() async throws {
        let (store, sid) = try makeStore()
        try store.append(sessionId: sid, message: .user("contexto viejo"))

        let wm = WorkingMemory(store: store)
        await wm.ingestCompaction([.text("[RESUMEN] lo esencial de la sesión")])
        let messages = try await wm.assemble(.text("sigue", sessionId: sid))

        #expect(messages.first?.role == .assistant)
        #expect(messages.first?.content == [.text("[RESUMEN] lo esencial de la sesión")])
    }

    /// El contexto activado (Fase 2) está vacío por ahora: no aparece ningún
    /// mensaje extra entre el system y el turn input.
    @Test func activatedContextIsEmptyWithoutBrain() async throws {
        let (store, sid) = try makeStore()
        let wm = WorkingMemory(store: store)
        let messages = try await wm.assemble(.text("hola", sessionId: sid))
        // Solo [system, user(turn)] — sin history, sin activado.
        #expect(messages.map(\.role) == [.system, .user])
    }

    /// Golden §5.1 posición 6: las memorias activadas del Brain entran como bloque
    /// etiquetado role:user DESPUÉS del mid-conversation system y ANTES del turn input.
    @Test func activatedMemoriesAppearInStablePosition() async throws {
        let (store, sid) = try makeStore()
        let wm = WorkingMemory(store: store)
        await wm.setActivatedMemories([
            ActivatedMemory(id: "m1", content: "Joshua vive en Bogota", kind: .semantic, confidence: 0.8, score: 0.1)
        ])
        let messages = try await wm.assemble(.text("¿dónde vivo?", sessionId: sid))

        // [system(selfView), user(activadas), user(turn)].
        #expect(messages.map(\.role) == [.system, .user, .user])
        let activatedIndex = messages.count - 2
        let turnIndex = messages.count - 1
        guard case .text(let block)? = messages[activatedIndex].content.first else {
            Issue.record("bloque activado ausente"); return
        }
        #expect(block.hasPrefix(WorkingMemory.activatedMemoriesHeader))
        #expect(block.contains("Joshua vive en Bogota"))
        #expect(messages[turnIndex].content == [.text("¿dónde vivo?")])
    }
}
