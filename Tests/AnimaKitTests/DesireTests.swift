import Foundation
import Testing
import GRDB
@testable import AnimaKit

@Suite struct DesireTests {

    private struct Rig {
        let queue: DatabaseQueue
        let other: OtherModel
        func engine(env: ObservableEnvironment,
                    now: @escaping @Sendable () -> Date = { Date() },
                    dailyBudget: Int = 4) throws -> DesireEngine {
            DesireEngine(otherModel: other, environment: env, queue: queue,
                         provider: MockProvider(events: .text("Te propongo agendar un bloque; ¿lo hago?")),
                         router: try .haikuAll(), authMode: .apiKey, token: "sk-ant-api03-x",
                         store: nil, dailyBudget: dailyBudget, now: now)
        }
    }

    private func makeRig(now: @escaping @Sendable () -> Date = { Date() }) throws -> Rig {
        let queue = try AnimaDatabase.temporary()
        return Rig(queue: queue, other: OtherModel(queue: queue, now: now))
    }

    // MARK: - Observables (evaluación local, 0 LLM)

    @Test func observablesEvaluateGapAndSatisfaction() async throws {
        let gap = await ObservablePredicate.workoutsPerWeek(atLeast: 3)
            .evaluate(in: MockObservableEnvironment(workouts: 1))
        #expect(!gap.satisfied)
        let ok = await ObservablePredicate.workoutsPerWeek(atLeast: 3)
            .evaluate(in: MockObservableEnvironment(workouts: 3))
        #expect(ok.satisfied)
    }

    @Test func observablePredicateCodableRoundTrips() throws {
        let cases: [ObservablePredicate] = [
            .workoutsPerWeek(atLeast: 3),
            .remindersOverdue(atMost: 0),
            .sleepHours(atLeast: 7, lastDays: 5),
            .calendarFreeSlot(minMinutes: 45, withinDays: 3),
            .daysSinceLastMention(topic: "tesis", atMost: 4),
        ]
        for predicate in cases {
            let data = try JSONEncoder().encode(predicate)
            let back = try JSONDecoder().decode(ObservablePredicate.self, from: data)
            #expect(back == predicate)
        }
    }

    // MARK: - Eval #4: CERO Intentions huérfanas (constraint FK + flujo)

    @Test func intentionWithoutGoalIsRejectedByConstraint() throws {
        let queue = try AnimaDatabase.temporary()
        // La FK goal_id NOT NULL REFERENCES goal(id) impide una Intention sin Goal.
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO intention (id, goal_id, observables_json, gap, proposed_text, outcome, created_at)
                    VALUES ('i1','fantasma','{}','gap','texto','pending', 0)
                    """)
            }
        }
    }

    @Test func statedGoalWithoutProgressProducesIntentionWithGoalId() async throws {
        let rig = try makeRig()
        let env = MockObservableEnvironment(workouts: 0,
                                            slots: [DateInterval(start: Date(), duration: 2700)])
        let gid = await rig.other.ingestStated(
            statement: "Joshua quiere entrenar 3x por semana",
            desiredState: .workoutsPerWeek(atLeast: 3),
            evidence: "\"quiero entrenar 3x por semana\"", priority: 7)

        let engine = try rig.engine(env: env)
        let produced = try await engine.pulse()
        #expect(produced.count == 1)
        #expect(produced.first?.goalId == gid)

        // El log auditable: la Intention existe y referencia su Goal.
        let all = await engine.allIntentions()
        #expect(all.count == 1)
        #expect(all.first?.goalId == gid)
        #expect(all.first?.gap.contains("0 de 3") == true)   // caso de aceptación
    }

    // MARK: - Gate de confirmación de Inferred (mismo inbox)

    @Test func inferredGoalDoesNotMotivateUntilConfirmed() async throws {
        let rig = try makeRig()
        let env = MockObservableEnvironment(workouts: 0)
        let iid = await rig.other.infer(statement: "Quizá quiere meditar a diario",
                                        desiredState: .workoutsPerWeek(atLeast: 3),
                                        evidence: "menciones sueltas")

        let engine = try rig.engine(env: env)
        // Inferred pendiente: no está en el deseo, no motiva ningún pulso.
        #expect(await engine.gaps().isEmpty)
        #expect(try await engine.pulse().isEmpty)
        #expect(await rig.other.pendingConfirmations().count == 1)

        // El dueño confirma en el inbox → active → recién ahora puede proponer.
        await rig.other.confirm(id: iid)
        let produced = try await engine.pulse()
        #expect(produced.count == 1)
        #expect(produced.first?.goalId == iid)
    }

    // MARK: - Presupuesto duro: ≤4 pulsos/día

    @Test func fifthPulseOfTheDayDoesNotRun() async throws {
        let clock = Locked(Date(timeIntervalSince1970: 1_000_000))
        let rig = try makeRig(now: { clock.value })
        let env = MockObservableEnvironment(workouts: 0)
        // Cinco metas distintas, todas con brecha, para aislar el presupuesto del cooldown.
        for i in 1...5 {
            _ = await rig.other.ingestStated(statement: "meta \(i)",
                                             desiredState: .workoutsPerWeek(atLeast: 3),
                                             evidence: "e\(i)")
        }
        let engine = try rig.engine(env: env)
        var produced = 0
        for _ in 1...5 {
            produced += try await engine.pulse().count
        }
        #expect(produced == 4)                       // el 5º no corre
        #expect(await engine.pulsesToday() == 4)
    }

    // MARK: - Cooldown 48h por goal

    @Test func sameGoalRespects48hCooldown() async throws {
        let clock = Locked(Date(timeIntervalSince1970: 1_000_000))
        let rig = try makeRig(now: { clock.value })
        let env = MockObservableEnvironment(workouts: 0)
        _ = await rig.other.ingestStated(statement: "entrenar 3x", desiredState: .workoutsPerWeek(atLeast: 3),
                                         evidence: "e")
        let engine = try rig.engine(env: env, now: { clock.value })

        #expect(try await engine.pulse().count == 1)
        // Mismo goal, <48h → cooldown, no propone otra vez.
        #expect(try await engine.pulse().isEmpty)
        // Pasan 49h → cooldown vencido (y nuevo día → presupuesto fresco).
        clock.mutate { $0 = $0.addingTimeInterval(49 * 3600) }
        #expect(try await engine.pulse().count == 1)
    }

    // MARK: - Precedencia dura del deseo (stated > inferred > structural)

    @Test func desireOrdersByPrecedence() async throws {
        let rig = try makeRig()
        _ = await rig.other.addStructural(statement: "no perder pendientes",
                                          desiredState: .remindersOverdue(atMost: 0))
        let sid = await rig.other.ingestStated(statement: "entrenar 3x",
                                               desiredState: .workoutsPerWeek(atLeast: 3), evidence: "e")
        let iid = await rig.other.infer(statement: "meditar", desiredState: .workoutsPerWeek(atLeast: 1),
                                        evidence: "e")
        await rig.other.confirm(id: iid)   // inferred confirmado sí motiva, pero tras stated

        let desire = await rig.other.desire()
        #expect(desire.first?.id == sid)                 // stated primero
        #expect(desire.map(\.source).contains(.structural))
    }
}
