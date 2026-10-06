import Foundation
import Testing
import GRDB
@testable import AnimaKit

@Suite struct PulseSchedulerTests {
    typealias F = ProactiveFixtures

    private func engine(_ w: F.World, env: ObservableEnvironment, dailyBudget: Int = 4) throws -> DesireEngine {
        DesireEngine(otherModel: w.other, environment: env, queue: w.queue,
                     provider: MockProvider(events: .text("¿Transferimos 200k al fondo hoy?")),
                     router: try .haikuAll(), authMode: .apiKey, token: "sk-ant-api03-x",
                     store: w.symbolic, dailyBudget: dailyBudget, now: { w.clock.value })
    }

    @Test func identifierAndEarliestBeginDate() {
        #expect(PulseScheduler.taskIdentifier == "mind.anima.pulse")
        #expect(PulseScheduler().earliestBeginDate(now: F.start) == F.start.addingTimeInterval(4 * 3600))
        #expect(PulseScheduler(interval: 60).earliestBeginDate(now: F.start) == F.start.addingTimeInterval(60))
    }

    @Test func backgroundIntentionBecomesNotificationOnlyWhenProduced() async throws {
        let w = try F.world(status: .granted)
        let sid = try w.symbolic.startSession()
        let goal = await w.other.ingestStated(statement: "invertir 10M", desiredState: .progressCheckIn(everyDays: 2),
                                              evidence: "")
        let runner = PulseRunner(reconciler: w.reconciler, engine: try engine(w, env: MockObservableEnvironment()),
                                 scheduler: w.scheduler)
        let outcome = await runner.run(sessionId: sid)
        let intention = try #require(outcome.intentions.first)
        #expect(intention.goalId == goal && intention.origin == .background)
        let request = try #require(w.fake.scheduled["anima-intention-\(intention.id)"])
        #expect(request.body == "¿Transferimos 200k al fondo hoy?" && request.title == "Lumen")
        #expect(request.deepLink == AnimaDeepLink.intention(id: intention.id).url)

        // Cooldown 48h: el siguiente pulso no produce nada ⇒ ninguna notificación nueva.
        let again = await runner.run(sessionId: sid)
        #expect(again.intentions.isEmpty)
        #expect(w.fake.scheduled.keys.filter { $0.hasPrefix("anima-intention-") }.count == 1)
    }

    @Test func noGapNoNotification() async throws {
        let w = try F.world(status: .granted)
        let goal = await w.other.ingestStated(statement: "correr", desiredState: .progressCheckIn(everyDays: 2),
                                              evidence: "")
        let runner = PulseRunner(reconciler: w.reconciler,
                                 engine: try engine(w, env: MockObservableEnvironment(progress: [goal: 0])),
                                 scheduler: w.scheduler)
        #expect(await runner.run(sessionId: nil).intentions.isEmpty)
        #expect(w.fake.scheduled.isEmpty)
    }

    @Test func dailyBudgetIsRespectedInBackground() async throws {
        let w = try F.world(status: .granted)
        _ = await w.other.ingestStated(statement: "a", desiredState: .progressCheckIn(everyDays: 2), evidence: "")
        _ = await w.other.ingestStated(statement: "b", desiredState: .progressCheckIn(everyDays: 2), evidence: "")
        let runner = PulseRunner(reconciler: nil,
                                 engine: try engine(w, env: MockObservableEnvironment(), dailyBudget: 1),
                                 scheduler: w.scheduler)
        #expect(await runner.run(sessionId: nil).intentions.count == 1)
        #expect(await runner.run(sessionId: nil).intentions.isEmpty)     // 2ª meta en gap, sin presupuesto
        #expect(w.fake.scheduled.keys.filter { $0.hasPrefix("anima-intention-") }.count == 1)
    }

    @Test func reconcilesDueRemindersAndResyncs() async throws {
        let w = try F.world(status: .granted)
        let sid = try w.symbolic.startSession()
        _ = try await w.reminders.create(text: "pagar la tarjeta", fireAt: F.date(2026, 10, 5, 15))
        let later = try await w.reminders.create(text: "llamar a mamá", fireAt: F.date(2026, 10, 6, 18))
        w.advance(2 * 3600)
        let outcome = await PulseRunner(reconciler: w.reconciler, engine: nil, scheduler: w.scheduler).run(sessionId: sid)
        #expect(outcome.delivered.map(\.text) == ["Te recuerdo: pagar la tarjeta"])
        #expect(outcome.intentions.isEmpty)
        #expect(await w.fake.pendingIds() == ["anima-reminder-\(later.id)"])
        #expect(await PulseRunner(reconciler: nil, engine: nil, scheduler: nil).run(sessionId: nil)
                == PulseRunner.Outcome(delivered: [], intentions: []))
    }

    @Test func foregroundPulseKeepsForegroundOriginAndLookup() async throws {
        let w = try F.world()
        _ = await w.other.ingestStated(statement: "a", desiredState: .progressCheckIn(everyDays: 2), evidence: "")
        let engine = try engine(w, env: MockObservableEnvironment())
        let produced = try #require(try await engine.pulse().first)
        #expect(produced.origin == .foreground)
        #expect(await engine.intention(id: produced.id) == produced)
        #expect(await engine.intention(id: "nope") == nil)
    }
}
