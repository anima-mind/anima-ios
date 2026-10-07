import Foundation
import Testing
import GRDB
@testable import AnimaKit

// Campo batch 8 #3: "cuando actualicé la app se me perdió el historial". Causa
// real: el chat solo cargaba la sesión actual (+ la anterior si era nueva). Al
// relanzar tras una sesión fresca SIN turnos (>8 h de inactividad, o un
// despertar en background que abre sesión) Recovery la reanudaba con
// previous=nil ⇒ chat vacío aunque la DB tenía todo. Ahora el chat pinta TODAS
// las sesiones, paginadas hacia arriba; la sesión solo define el contexto.

@Suite("Batch 8 #3 — historial completo, paginado y fijo")
struct FullHistoryStoreTests {

    @Test func laPaginaCruzaSesionesYSaltaLoNoVisible() throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let s1 = try store.startSession()
        try store.append(sessionId: s1, message: .user("ayer"))
        try store.append(sessionId: s1, message: Message(role: .assistant, content: [
            .text("Déjame ver."), .toolUse(id: "t", name: "calendar", input: .null)]))
        try store.append(sessionId: s1, message: Message(role: .user, content: [
            .toolResult(toolUseId: "t", content: "[]", isError: false)]))
        try store.append(sessionId: s1, message: .assistant([.text("Libre.")]))
        let s2 = try store.startSession()
        try store.append(sessionId: s2, message: .user("hoy"))

        let page = try store.historyPage()
        #expect(page.turns.map(\.text) == ["ayer", "Déjame ver.", "Libre.", "hoy"])
        #expect(page.turns.map(\.sessionId) == [s1, s1, s1, s2])
        #expect(!page.hasMore)
        #expect(page.turns.allSatisfy { $0.rowId != nil })
    }

    @Test func paginasDe50HaciaArriba() throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let sid = try store.startSession()
        for i in 0..<120 { try store.append(sessionId: sid, message: .user("m\(i)")) }
        let first = try store.historyPage()
        #expect(first.turns.count == SymbolicStore.historyPageSize)
        #expect(first.turns.first?.text == "m70")
        #expect(first.turns.last?.text == "m119")
        #expect(first.hasMore)
        let second = try store.historyPage(before: first.oldestRowId)
        #expect(second.turns.map(\.text).first == "m20")
        #expect(second.hasMore)
        let third = try store.historyPage(before: second.oldestRowId)
        #expect(third.turns.count == 20)
        #expect(!third.hasMore)
        #expect(try store.historyPage(before: third.oldestRowId).turns.isEmpty)
    }

    @Test func soloEventosNoVisiblesAntesNoCuentanComoMas() throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let sid = try store.startSession()
        for _ in 0..<70 {
            try store.append(sessionId: sid, message: Message(role: .user, content: [
                .toolResult(toolUseId: "t", content: "x", isError: false)]))
        }
        try store.append(sessionId: sid, message: .user("único"))
        let page = try store.historyPage()
        #expect(page.turns.map(\.text) == ["único"])
        #expect(page.hasMore)   // hay filas user viejas (tool_result): la próxima página sale vacía
        #expect(try store.historyPage(before: page.oldestRowId).turns.isEmpty)
    }

    /// El escenario del dueño: hablar, quedar inactivo >8 h (sesión nueva SIN
    /// turnos), relanzar (Recovery reanuda la vacía con previous=nil) ⇒ el chat
    /// sigue mostrando lo de antes.
    @MainActor
    @Test func relanzarConSesionNuevaVaciaSigueMostrandoLoViejo() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let recovery = Recovery(queue: queue, store: store)
        let old = try store.startSession()
        try store.append(sessionId: old, message: .user("mi historial"))
        try store.append(sessionId: old, message: .assistant([.text("guardado")]))
        try store.markCleanShutdown(old)
        let later = Date().addingTimeInterval(9 * 3600)
        #expect(try recovery.decideLaunch(now: later) == .fresh(previous: old))
        let fresh = try store.startSession()
        try store.markCleanShutdown(fresh)
        // Segundo lanzamiento: reanuda la sesión vacía SIN anterior (la causa raíz).
        #expect(try recovery.decideLaunch(now: Date()) == .resume(fresh))
        #expect(try store.visibleTurns(sessionId: fresh).isEmpty)

        let chat = ChatViewModel(loop: try Self.loop(store, queue), sessionId: fresh)
        chat.historyStore = store
        chat.loadHistory(page: try store.historyPage())
        #expect(chat.messages.map(\.text) == ["mi historial", "guardado", ChatViewModel.newConversationText])
        // Las filas siguen en la DB: nada se borra.
        let count = try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM turn_event") }
        #expect(count == 2)
    }

    static func loop(_ store: SymbolicStore, _ queue: DatabaseQueue) throws -> AgentLoop {
        AgentLoop(provider: CapturingProvider([]), store: store, telemetry: Telemetry(queue: queue),
                  router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                  token: "sk-ant-api03-xyz", clientTools: [], serverTools: [], sleep: { _ in })
    }
}

@Suite("Batch 8 #3 — separadores de conversación y de contexto")
@MainActor
struct FullHistoryChatTests {

    private func turn(_ text: String, _ sid: SessionID, seq: Int, row: Int64,
                      role: Message.Role = .user) -> VisibleTurn {
        var t = VisibleTurn(role: role, text: text)
        t.sessionId = sid
        t.seq = seq
        t.rowId = row
        return t
    }

    @Test func separadoresEntreSesionesYFronteras() {
        let compaction = ContextBoundary(kind: .compaction, fromSeq: 3, summary: "r", createdAt: Date())
        let turns = [turn("a", "s1", seq: 1, row: 1), turn("b", "s1", seq: 2, row: 2),
                     turn("c", "s1", seq: 3, row: 3), turn("d", "s2", seq: 1, row: 4)]
        let messages = ChatViewModel.history(turns: turns, boundaries: ["s1": [compaction]])
        #expect(messages.map(\.text) == ["a", "b", "Conversación compactada", "c", "— nueva conversación —", "d"])
        #expect(messages.filter(\.isSessionDivider).count == 2)
    }

    @Test func fronteraAlFinalDeUnaSesionSePintaAntesDelSeparador() {
        let trailing = ContextBoundary(kind: .compaction, fromSeq: 5, summary: "r", createdAt: Date())
        let turns = [turn("a", "s1", seq: 1, row: 1), turn("d", "s2", seq: 1, row: 2)]
        let messages = ChatViewModel.history(turns: turns, boundaries: ["s1": [trailing]])
        #expect(messages.map(\.text) == ["a", "Conversación compactada", "— nueva conversación —", "d"])
        // Sesión actual compactada sin turnos nuevos aún: el separador va al final.
        let current = ChatViewModel.history(turns: [turn("a", "s1", seq: 1, row: 1)], boundaries: ["s1": [trailing]])
        #expect(current.map(\.text) == ["a", "Conversación compactada"])
    }

    @Test func paginasUnidasNoDuplicanNiPierdenSeparadores() {
        let compaction = ContextBoundary(kind: .compaction, fromSeq: 3, summary: "r", createdAt: Date())
        let all = [turn("a", "s1", seq: 1, row: 1), turn("b", "s1", seq: 2, row: 2),
                   turn("c", "s1", seq: 3, row: 3), turn("d", "s2", seq: 1, row: 4)]
        let whole = ChatViewModel.history(turns: all, boundaries: ["s1": [compaction]]).map(\.text)
        // Corte justo en la frontera: la página nueva arranca en "c" (seq 3).
        let newer = ChatViewModel.history(turns: Array(all[2...]), boundaries: ["s1": [compaction]], leadingCut: true)
        let older = ChatViewModel.history(turns: Array(all[..<2]), boundaries: ["s1": [compaction]],
                                          following: all[2])
        #expect((older + newer).map(\.text) == whole)
        // Corte entre sesiones: el separador lo pone la página vieja.
        let newer2 = ChatViewModel.history(turns: [all[3]], boundaries: [:], leadingCut: true)
        let older2 = ChatViewModel.history(turns: Array(all[..<3]), boundaries: ["s1": [compaction]],
                                           following: all[3])
        #expect((older2 + newer2).map(\.text) == whole)
    }

    @Test func scrollAlTopeCargaLaPaginaAnteriorYReancla() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let s1 = try store.startSession()
        for i in 0..<30 { try store.append(sessionId: s1, message: .user("viejo\(i)")) }
        let s2 = try store.startSession()
        for i in 0..<60 { try store.append(sessionId: s2, message: .user("nuevo\(i)")) }
        let chat = ChatViewModel(loop: try FullHistoryStoreTests.loop(store, queue), sessionId: s2)
        chat.historyStore = store
        chat.loadHistory(page: try store.historyPage())
        #expect(chat.messages.count == 50)
        #expect(chat.hasOlderHistory)
        let firstShown = chat.messages.first?.id
        let anchor = await chat.loadOlderHistory()
        #expect(anchor == firstShown)
        #expect(chat.messages.first?.text == "viejo0")
        #expect(chat.messages.contains { $0.isSessionDivider && $0.text == ChatViewModel.newConversationText })
        #expect(chat.messages.filter { !$0.isSessionDivider }.count == 90)
        #expect(!chat.hasOlderHistory)
        #expect(await chat.loadOlderHistory() == nil)
    }

    @Test func sinStoreNoPagina() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let chat = ChatViewModel(loop: try FullHistoryStoreTests.loop(store, queue), sessionId: try store.startSession())
        #expect(await chat.loadOlderHistory() == nil)
        chat.loadHistory(page: try store.historyPage())
        #expect(chat.messages.isEmpty)
        #expect(!chat.hasOlderHistory)
    }
}
