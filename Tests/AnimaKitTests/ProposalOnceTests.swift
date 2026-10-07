import Foundation
import Testing
import GRDB
@testable import AnimaKit

// Campo batch 8 #1: "es raro que se vea doble el mensaje de la AI… que se vea
// el mensaje del chat y el botón de aceptar y rechazar sin repetirlo".
// DesireEngine.drive persistía la propuesta como turno assistant SIN marca y el
// chat además la pintaba como card: el texto salía dos veces.

@MainActor
@Suite("Batch 8 #1 — la propuesta se ve una sola vez, como card")
struct ProposalOnceTests {
    nonisolated static let proposal = "¿El miércoles a las 8:00 hacemos tu primer check-in?"

    private func rig() throws -> (DatabaseQueue, SymbolicStore, OtherModel, DesireEngine) {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let other = OtherModel(queue: queue)
        let engine = DesireEngine(otherModel: other, environment: MockObservableEnvironment(workouts: 0),
                                  queue: queue, provider: MockProvider(events: .text(Self.proposal)),
                                  router: try .haikuAll(), authMode: .apiKey, token: "sk-ant-api03-x", store: store)
        return (queue, store, other, engine)
    }

    private func chat(_ store: SymbolicStore, _ queue: DatabaseQueue, _ sid: SessionID,
                      _ engine: DesireEngine) throws -> ChatViewModel {
        let loop = AgentLoop(provider: CapturingProvider([.text("Listo.")]), store: store,
                             telemetry: Telemetry(queue: queue), router: ModelRouter(config: try TestConfig.providerConfig()),
                             authMode: .apiKey, token: "sk-ant-api03-xyz", clientTools: [], serverTools: [], sleep: { _ in })
        let chat = ChatViewModel(loop: loop, sessionId: sid, desireEngine: engine)
        chat.historyStore = store
        return chat
    }

    @Test func elPulsoPersisteElTurnoMarcadoYElChatPintaUnaSolaCard() async throws {
        let (queue, store, other, engine) = try rig()
        _ = await other.ingestStated(statement: "Entrenar 3 veces por semana", desiredState: .workoutsPerWeek(atLeast: 3),
                                     evidence: "e")
        let sid = try store.startSession()
        let produced = try await engine.pulse(sessionId: sid)
        let intention = try #require(produced.first)
        let turns = try store.visibleTurns(sessionId: sid)
        #expect(turns.count == 1)
        #expect(turns.first?.proactive == ProactiveTag(kind: "intention", ref: intention.id,
                                                       at: intention.createdAt.timeIntervalSince1970))

        // Relanzar: historial + pendientes ⇒ UNA card, ningún texto suelto.
        let chat = try chat(store, queue, sid, engine)
        chat.loadHistory(page: try store.historyPage())
        await chat.loadProactiveIntentions()
        let withText = chat.messages.filter { $0.text == Self.proposal }
        #expect(withText.count == 1)
        #expect(withText.first?.intentionId == intention.id && withText.first?.isProactive == true)
        #expect(withText.first?.resolved == false)

        // Hagámoslo: la card queda resuelta y el dueño ve "Hagámoslo", no la propuesta repetida.
        await chat.accept(try #require(withText.first))
        #expect(chat.messages.filter { $0.text == Self.proposal }.count == 1)
        #expect(chat.messages.contains { $0.role == .user && $0.text == IntentionAcceptance.shownText })

        // Otro relanzamiento: la card restaurada muestra el resultado (sin botones).
        let again = try self.chat(store, queue, sid, engine)
        again.loadHistory(page: try store.historyPage())
        await again.loadProactiveIntentions()
        let card = try #require(again.messages.first { $0.intentionId == intention.id })
        #expect(card.outcome == .accepted && card.resolved)
        #expect(again.messages.filter { $0.text == Self.proposal }.count == 1)
        #expect(again.messages.contains { $0.role == .user && $0.text == IntentionAcceptance.shownText })
    }

    @Test func recordProposalEsElMismoCaminoQueElPulso() async throws {
        let (_, store, other, engine) = try rig()
        let gid = await other.ingestStated(statement: "Bajar 10 kg", desiredState: .progressCheckIn(everyDays: 7),
                                           evidence: "e")
        let goal = try #require(await other.goal(id: gid))
        let sid = try store.startSession()
        let intention = await engine.recordProposal(goal: goal, text: Self.proposal, sessionId: sid)
        #expect(await engine.pendingIntentions().map(\.id) == [intention.id])
        #expect(try store.visibleTurns(sessionId: sid).first?.proactive?.ref == intention.id)
        _ = await engine.recordProposal(goal: goal, text: "sin sesión", sessionId: nil)
        #expect(try store.visibleTurns(sessionId: sid).count == 1)
    }

    @Test func laMigracionMarcaLasPropuestasViejas() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try AnimaDatabase.migrator().migrate(queue, upTo: "v17-goal-dedupe")
        let store = SymbolicStore(queue: queue)
        let sid = try store.startSession()
        let now = Date().timeIntervalSince1970
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO goal (id, statement, predicate_json, source, status, created_at, updated_at)
                VALUES ('g','Bajar 10 kg','{}','stated','active',?,?)
                """, arguments: [now, now])
            try db.execute(sql: """
                INSERT INTO intention (id, goal_id, observables_json, gap, proposed_text, outcome, created_at)
                VALUES ('i1','g','{}','gap',?,'pending',?)
                """, arguments: [Self.proposal, now])
        }
        // El turno legacy: mismo texto, sin marca (como lo escribía drive()).
        try store.append(sessionId: sid, message: .assistant([.text(Self.proposal)]))
        try store.append(sessionId: sid, message: .assistant([.text("otra cosa")]))
        try AnimaDatabase.migrator().migrate(queue)
        let turns = try store.visibleTurns(sessionId: sid)
        #expect(turns.first?.proactive?.kind == "intention" && turns.first?.proactive?.ref == "i1")
        #expect(turns.last?.proactive == nil)
        let messages = ChatViewModel.history(turns: turns, boundaries: [:])
        #expect(messages.first?.intentionId == "i1")
        // Idempotente.
        #expect(try await queue.write { db in try IntentionTurnRepair.run(db) } == 0)
    }
}
