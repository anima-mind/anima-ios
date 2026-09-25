import Foundation
import Testing
import GRDB
@testable import AnimaKit

@Suite struct OtherModelLifecycleTests {

    private func model(clock: Locked<Date> = Locked(Date(timeIntervalSince1970: 1_000))) throws -> (OtherModel, DatabaseQueue, Locked<Date>) {
        let queue = try AnimaDatabase.temporary()
        return (OtherModel(queue: queue, now: { clock.value }), queue, clock)
    }

    @Test func restatingAGoalUpdatesEvidenceInsteadOfDuplicating() async throws {
        let (other, _, clock) = try model()
        let first = await other.ingestStated(statement: "  entrenar 3x  ", desiredState: .workoutsPerWeek(atLeast: 3),
                                             evidence: "lo dijo el lunes")
        clock.mutate { $0 = $0.addingTimeInterval(60) }
        let again = await other.ingestStated(statement: "entrenar 3x", desiredState: .workoutsPerWeek(atLeast: 3),
                                             evidence: "lo repitió el martes")
        #expect(first == again)
        let goal = try #require(await other.goal(id: first))
        #expect(goal.evidence == "lo repitió el martes")
        #expect(goal.statement == "entrenar 3x")
        #expect(goal.updatedAt > goal.createdAt)
        #expect(await other.allGoals().count == 1)
    }

    @Test func abandonedGoalLeavesDesireAndCanBeRestatedFresh() async throws {
        let (other, _, _) = try model()
        let id = await other.ingestStated(statement: "leer más", desiredState: .daysSinceLastMention(topic: "libro", atMost: 3),
                                          evidence: "e")
        await other.abandon(id: id)
        #expect(await other.goal(id: id)?.status == .abandoned)
        #expect(await other.desire().isEmpty)
        let fresh = await other.ingestStated(statement: "leer más", desiredState: .daysSinceLastMention(topic: "libro", atMost: 3),
                                             evidence: "otra vez")
        #expect(fresh != id)
    }

    @Test func achievedGoalStopsMotivating() async throws {
        let (other, _, _) = try model()
        let id = await other.addStructural(statement: "no perder pendientes", desiredState: .remindersOverdue(atMost: 0))
        #expect(await other.desire().map(\.id) == [id])
        await other.markAchieved(id: id)
        #expect(await other.goal(id: id)?.status == .achieved)
        #expect(await other.desire().isEmpty)
        #expect(await other.goal(id: "no-existe") == nil)
    }

    @Test func desireOrdersByPrecedenceThenPriorityThenStaleness() async throws {
        let (other, _, clock) = try model()
        let structural = await other.addStructural(statement: "s", desiredState: .remindersOverdue(atMost: 0), priority: 9)
        clock.mutate { $0 = $0.addingTimeInterval(10) }
        let statedLow = await other.ingestStated(statement: "a", desiredState: .workoutsPerWeek(atLeast: 1),
                                                 evidence: "e", priority: 3)
        clock.mutate { $0 = $0.addingTimeInterval(10) }
        let statedHighNew = await other.ingestStated(statement: "b", desiredState: .workoutsPerWeek(atLeast: 1),
                                                     evidence: "e", priority: 8)
        clock.mutate { $0 = $0.addingTimeInterval(-100) }  // más viejo sin tocar
        let statedHighOld = await other.ingestStated(statement: "c", desiredState: .workoutsPerWeek(atLeast: 1),
                                                     evidence: "e", priority: 8)
        #expect(await other.desire().map(\.id) == [statedHighOld, statedHighNew, statedLow, structural])
    }

    @Test func corruptPredicateDegradesToSafeDefault() async throws {
        let (other, queue, _) = try model()
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO goal (id, statement, predicate_json, source, status, priority, evidence,
                                  confirmed_by_other, created_at, updated_at)
                VALUES ('g1','x','{"kind":"inventado"}','stated','active',5,'e',0,0,0)
                """)
        }
        #expect(await other.goal(id: "g1")?.desiredState == .remindersOverdue(atMost: 0))
    }
}

@Suite struct DesireEngineLifecycleTests {

    private func rig(_ provider: Provider = MockProvider(events: .text("¿Agendo 45 min para entrenar?")),
                     withStore: Bool = false) throws
        -> (DesireEngine, OtherModel, SymbolicStore, Telemetry, DatabaseQueue) {
        let queue = try AnimaDatabase.temporary()
        let other = OtherModel(queue: queue)
        let store = SymbolicStore(queue: queue)
        let telemetry = Telemetry(queue: queue)
        let engine = DesireEngine(otherModel: other, environment: MockObservableEnvironment(workouts: 0),
                                  queue: queue, provider: provider, router: try .haikuAll(),
                                  authMode: .apiKey, token: "sk-ant-api03-x",
                                  store: withStore ? store : nil, telemetry: telemetry)
        return (engine, other, store, telemetry, queue)
    }

    @Test func proposalIsPersistedAsProactiveTurnAndTelemetry() async throws {
        let (engine, other, store, telemetry, _) = try rig(withStore: true)
        _ = await other.ingestStated(statement: "entrenar", desiredState: .workoutsPerWeek(atLeast: 3), evidence: "e")
        let sid = try store.startSession()
        let produced = try await engine.pulse(sessionId: sid)
        #expect(produced.first?.proposedText == "¿Agendo 45 min para entrenar?")
        let window = try store.window(sessionId: sid)
        #expect(window.last == .assistant([.text("¿Agendo 45 min para entrenar?")]))
        #expect(try telemetry.summary().contains { $0.turnClass == TurnClass.desirePulse.rawValue })
    }

    @Test func emptyDraftFallsBackToDeterministicText() async throws {
        let (engine, other, _, _, _) = try rig(MockProvider(events: .text("   ")))
        _ = await other.ingestStated(statement: "entrenar 3x", desiredState: .workoutsPerWeek(atLeast: 3), evidence: "e")
        let produced = try await engine.pulse()
        #expect(produced.first?.proposedText
                == "Sobre 'entrenar 3x': entrenamientos esta semana: 0 de 3. ¿Quieres que te ayude a avanzar?")
    }

    @Test func outcomesResolvePendingIntentions() async throws {
        let (engine, other, _, _, _) = try rig()
        _ = await other.ingestStated(statement: "entrenar", desiredState: .workoutsPerWeek(atLeast: 3), evidence: "e")
        let intention = try #require(try await engine.pulse().first)
        #expect(await engine.pendingIntentions().map(\.id) == [intention.id])
        await engine.recordOutcome(id: intention.id, outcome: .accepted)
        #expect(await engine.pendingIntentions().isEmpty)
        #expect(await engine.allIntentions().first?.outcome == .accepted)
    }

    @Test func statedGapOutranksStructuralGap() async throws {
        let (engine, other, _, _, _) = try rig()
        _ = await other.addStructural(statement: "estructural", desiredState: .workoutsPerWeek(atLeast: 1), priority: 10)
        let stated = await other.ingestStated(statement: "declarada", desiredState: .workoutsPerWeek(atLeast: 1),
                                              evidence: "e", priority: 1)
        #expect(try await engine.pulse().first?.goalId == stated)
    }

    @Test func missingCortexFailsTheDraft() async throws {
        let queue = try AnimaDatabase.temporary()
        let other = OtherModel(queue: queue)
        _ = await other.ingestStated(statement: "entrenar", desiredState: .workoutsPerWeek(atLeast: 3), evidence: "e")
        let selector = ProviderSelector(mode: .claude, claude: nil, local: nil, availability: { .available })
        let engine = DesireEngine(otherModel: other, environment: MockObservableEnvironment(), queue: queue,
                                  selector: selector)
        await #expect(throws: ClassifiedError.self) { _ = try await engine.pulse() }
        #expect(await engine.allIntentions().isEmpty)  // sin córtex no se inventa una propuesta
    }
}

@Suite struct BrainBrowserTests {

    private func brain() throws -> Brain {
        Brain(queue: try AnimaDatabase.temporary(), embedder: Embedder(forceFallback: true))
    }

    @Test func browseFiltersByText() async throws {
        let b = try brain()
        _ = try await b.add(MemoryCandidate(content: "Joshua vive en Bogotá"))
        _ = try await b.add(MemoryCandidate(content: "Prefiere café sin azúcar"))
        #expect(try await b.browse(filter: "café").map(\.content) == ["Prefiere café sin azúcar"])
        #expect(try await b.browse(filter: "   ").count == 2)  // filtro en blanco = sin filtro
        #expect(try await b.browse(limit: 1).count == 1)
    }

    @Test func lastUsedTracksUsageLog() async throws {
        let b = try brain()
        let id = try await b.add(MemoryCandidate(content: "x"))
        #expect(try await b.lastUsed(id) == nil)
        try await b.usageLog(memoryId: id, sessionId: "s1", outcome: .success)
        #expect(try await b.lastUsed(id) != nil)
    }

    @Test func revisionChainWalksBothDirections() async throws {
        let b = try brain()
        let v1 = try await b.add(MemoryCandidate(content: "reuniones en la mañana"))
        let v2 = try await b.add(MemoryCandidate(content: "reuniones 8-10am"), revises: v1)
        let v3 = try await b.add(MemoryCandidate(content: "reuniones 8-9am"), revises: v2)
        let expected = [v1, v2, v3]
        #expect(try await b.revisionChain(v2).map(\.id) == expected)
        #expect(try await b.revisionChain(v1).map(\.id) == expected)
        #expect(try await b.revisionChain(v3).map(\.id) == expected)
        #expect(try await b.revisionChain("no-existe").isEmpty)
    }
}
