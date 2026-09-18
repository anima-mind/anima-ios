import Foundation
import Testing
import GRDB
@testable import AnimaKit

@Suite struct SymbolicStoreTests {

    @Test func sessionAndMessageRoundtrip() throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let sid = try store.startSession()

        let user = Message.user("¿qué notas tengo?")
        let assistant = Message.assistant([
            .thinking("debería listar"),
            .text("Déjame revisar."),
            .toolUse(id: "toolu_1", name: "notes", input: .object(["action": .string("list")])),
        ])
        let toolResult = Message.user([.toolResult(toolUseId: "toolu_1", content: "nota1\nnota2", isError: false)])

        try store.append(sessionId: sid, message: user)
        try store.append(sessionId: sid, message: assistant, usage: Usage(inputTokens: 100, outputTokens: 50))
        try store.append(sessionId: sid, message: toolResult)

        let window = try store.window(sessionId: sid)
        #expect(window == [user, assistant, toolResult])
        // tool_use y tool_result sobreviven el roundtrip íntegros.
        #expect(window[1].content.contains(.toolUse(id: "toolu_1", name: "notes",
                                                    input: .object(["action": .string("list")]))))
        #expect(window[2].content.contains(.toolResult(toolUseId: "toolu_1", content: "nota1\nnota2", isError: false)))
    }

    @Test func windowRespectsTokenBudget() throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let sid = try store.startSession()
        for i in 0..<10 {
            try store.append(sessionId: sid, message: .user(String(repeating: "x", count: 400) + "\(i)"))
        }
        // budget pequeño → conserva solo los más recientes.
        let window = try store.window(sessionId: sid, budgetTokens: 200)
        #expect(window.count < 10)
        #expect(window.count >= 1)
        // El último mensaje siempre sobrevive.
        #expect(window.last?.content.first == .text(String(repeating: "x", count: 400) + "9"))
    }

    // MARK: - Recovery (§5.2)

    @Test func recoveryResumesRecentDirtySession() throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let recovery = Recovery(queue: queue, store: store)

        let sid = try store.startSession()
        try store.append(sessionId: sid, message: .user("a mitad de turno"))  // last_event_at = ahora
        // No se marcó clean_shutdown → la app "murió".

        let decision = try recovery.decide()
        #expect(decision == .resume(sid))
        // Reanudar incrementa restart_count.
        #expect(try store.session(sid)?.restartCount == 1)
    }

    @Test func recoveryFreshAfterCleanShutdown() throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let recovery = Recovery(queue: queue, store: store)

        let sid = try store.startSession()
        try store.append(sessionId: sid, message: .user("hola"))
        try store.markCleanShutdown(sid)

        #expect(try recovery.decide() == .fresh)
    }

    @Test func recoveryFreshWhenStale() throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let recovery = Recovery(queue: queue, store: store, resumeWindow: 120)

        let sid = try store.startSession()
        try store.append(sessionId: sid, message: .user("hace rato"))
        // Backdatea last_event_at 200s en el pasado (> ventana de 120s).
        let old = Date().timeIntervalSince1970 - 200
        try queue.write { db in
            try db.execute(sql: "UPDATE session SET last_event_at=? WHERE id=?", arguments: [old, sid])
        }
        #expect(try recovery.decide() == .fresh)
    }

    @Test func recoveryFreshWhenTooManyRestarts() throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let recovery = Recovery(queue: queue, store: store, maxRestarts: 3)

        let sid = try store.startSession()
        try store.append(sessionId: sid, message: .user("loop"))
        try queue.write { db in
            try db.execute(sql: "UPDATE session SET restart_count=3 WHERE id=?", arguments: [sid])
        }
        #expect(try recovery.decide() == .fresh)
    }
}
