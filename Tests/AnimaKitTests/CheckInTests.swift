import Foundation
import Testing
import GRDB
@testable import AnimaKit

@Suite struct CheckInModelTests {
    typealias F = ProactiveFixtures

    private func other(_ w: F.World) -> OtherModel {
        OtherModel(queue: w.queue, calendar: F.calendar, now: { w.clock.value })
    }

    @Test func cadenceValidityAndPhrases() {
        #expect(CheckInCadence.off.isActive == false)
        #expect(CheckInCadence(cadence: .daily).phrase == "cada día a las 20:00")
        #expect(CheckInCadence(cadence: .weekdays, hour: 7, minute: 30).phrase == "entre semana a las 07:30")
        #expect(CheckInCadence(cadence: .weekly, hour: 9, weekday: 2).phrase == "cada lunes a las 09:00")
        #expect(CheckInCadence(cadence: .weekly, weekday: nil).phrase.hasPrefix("cada lunes"))
        #expect(CheckInCadence.off.phrase == "sin check-in")
        #expect(CheckInCadence(cadence: .daily, hour: 24).isValid == false)
        #expect(CheckInCadence(cadence: .daily, minute: 60).isValid == false)
        #expect(CheckInCadence(cadence: .weekly, weekday: nil).isValid == false)
        #expect(CheckInCadence(cadence: .weekly, weekday: 8).isValid == false)
        #expect(CheckInCadence.weekdayName(1) == "domingo" && CheckInCadence.weekdayName(7) == "sábado")
        #expect(CheckInCadence.weekdayName(0) == "domingo")
        #expect(CheckInAnswer.partial.isProgress && !CheckInAnswer.no.isProgress)
    }

    @Test func setAndClearCheckInPersistOnGoal() async throws {
        let w = try F.world()
        let other = other(w)
        let id = await other.ingestStated(statement: "invertir", desiredState: .progressCheckIn(everyDays: 2),
                                          evidence: "")
        #expect(await other.goal(id: id)?.checkIn == .off)
        #expect(await other.setCheckIn(id: id, CheckInCadence(cadence: .weekly, hour: 9, minute: 15, weekday: 4)))
        #expect(await other.goal(id: id)?.checkIn == CheckInCadence(cadence: .weekly, hour: 9, minute: 15, weekday: 4))
        #expect(await other.setCheckIn(id: id, CheckInCadence(cadence: .daily, hour: 7, weekday: 4)))
        #expect(await other.goal(id: id)?.checkIn.weekday == nil)    // weekday solo para weekly
        #expect(await other.setCheckIn(id: id, CheckInCadence(cadence: .daily, hour: 30)) == false)
        #expect(await other.setCheckIn(id: "nope", CheckInCadence(cadence: .daily)) == false)
        #expect(await other.clearCheckIn(id: id))
        let cleared = try #require(await other.goal(id: id)?.checkIn)
        #expect(cleared.cadence == .none && cleared.hour == 7)
        #expect(await other.clearCheckIn(id: "nope") == false)
    }

    @Test func recordAnswersOpenQuestionOrCreatesRow() async throws {
        let w = try F.world()
        let other = other(w)
        let id = await other.ingestStated(statement: "invertir", desiredState: .progressCheckIn(everyDays: 2),
                                          evidence: "")
        #expect(await other.markCheckInAsked(goalId: "nope") == nil)
        #expect(await other.recordCheckIn(goalId: "nope", answer: .yes) == nil)

        let asked = try #require(await other.markCheckInAsked(goalId: id))
        #expect(await other.lastCheckIn(goalId: id)?.answer == nil)
        #expect(await other.answeredToday(goalId: id) == false)
        w.advance(600)
        let answered = try #require(await other.recordCheckIn(goalId: id, answer: .partial, note: "500k"))
        #expect(answered.id == asked && answered.answer == .partial && answered.note == "500k")
        #expect(answered.answeredAt == F.start.addingTimeInterval(600))
        #expect(await other.answeredToday(goalId: id))

        let second = try #require(await other.recordCheckIn(goalId: id, answer: .no))
        #expect(second.id != asked)
        #expect(await other.checkIns(goalId: id).count == 2)
    }

    @Test func streakCountsConsecutiveProgressDays() async throws {
        let w = try F.world()
        let other = other(w)
        let id = await other.ingestStated(statement: "correr", desiredState: .progressCheckIn(everyDays: 2),
                                          evidence: "")
        #expect(await other.streak(goalId: id) == 0)
        #expect(await other.daysSinceProgress(goalId: id) == nil)
        // jueves sí, viernes no (rompe), sábado a medias, domingo sí (hoy lunes sin responder).
        for (day, answer) in [(1, CheckInAnswer.yes), (2, .no), (3, .partial), (4, .yes)] {
            w.clock.mutate { $0 = F.date(2026, 10, day, 21) }
            await other.recordCheckIn(goalId: id, answer: answer)
        }
        w.clock.mutate { $0 = F.date(2026, 10, 5, 10) }
        #expect(await other.streak(goalId: id) == 2)               // ayer y anteayer
        #expect(await other.daysSinceProgress(goalId: id) == 0)    // 13h desde el domingo 21:00
        await other.recordCheckIn(goalId: id, answer: .yes)
        #expect(await other.streak(goalId: id) == 3)
        w.clock.mutate { $0 = F.date(2026, 10, 8, 10) }
        #expect(await other.streak(goalId: id) == 0)
        #expect(await other.daysSinceProgress(goalId: id) == 3)
    }
}

@Suite struct ProgressPredicateTests {
    @Test func progressCheckInEvaluatesAgainstTheGoal() async {
        let p = ObservablePredicate.progressCheckIn(everyDays: 2)
        let env = MockObservableEnvironment(progress: ["g1": 1, "g2": 2])
        #expect(await p.evaluate(in: env, goalId: "g1")
                == ObservableReading(satisfied: true, detail: "último avance hace 1 días (cada 2)"))
        #expect(await p.evaluate(in: env, goalId: "g2").satisfied == false)
        #expect(await p.evaluate(in: env, goalId: "g3")
                == ObservableReading(satisfied: false, detail: "sin check-ins con avance todavía"))
        #expect(await p.evaluate(in: env).satisfied == false)
        #expect(p.label == "reportar avance al menos cada 2 días")
    }

    @Test func progressCheckInCodable() throws {
        let json = #"{"kind":"progress_check_in","every_days":3}"#
        let decoded = try JSONDecoder().decode(ObservablePredicate.self, from: Data(json.utf8))
        #expect(decoded == .progressCheckIn(everyDays: 3))
        let fallback = try JSONDecoder().decode(ObservablePredicate.self, from: Data(#"{"kind":"progress_check_in"}"#.utf8))
        #expect(fallback == .progressCheckIn(everyDays: 7))
        #expect(GoalsTool.predicate(from: .object(["kind": .string("progress_check_in"), "every_days": .int(0)]))
                == .progressCheckIn(everyDays: 1))
    }

    @Test func consolidatorPromptsOfferTheNewKind() {
        #expect(Consolidator.goalsPrompt.contains("progress_check_in{every_days}"))
        #expect(Consolidator.reflectionPrompt.contains("progress_check_in{every_days}"))
    }

    /// El DesireEngine evalúa el predicado contra SU meta (goalId).
    @Test func desireGapUsesGoalProgress() async throws {
        let queue = try AnimaDatabase.temporary()
        let other = OtherModel(queue: queue)
        let stale = await other.ingestStated(statement: "invertir", desiredState: .progressCheckIn(everyDays: 2),
                                             evidence: "")
        let fresh = await other.ingestStated(statement: "correr", desiredState: .progressCheckIn(everyDays: 2),
                                             evidence: "")
        let engine = DesireEngine(otherModel: other, environment: MockObservableEnvironment(progress: [fresh: 0]),
                                  queue: queue, provider: MockProvider(events: []),
                                  router: try ModelRouter.haikuAll(), authMode: .apiKey, token: "t")
        #expect(await engine.gaps().map(\.goal.id) == [stale])
    }
}

@Suite struct MentionIndexTests {
    @Test func findsMostRecentUserMentionInDays() throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let sid = try store.startSession()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let index = MentionIndex(queue: queue, now: { now })
        #expect(index.daysSinceLastMention(topic: "Guitarra") == nil)
        #expect(index.daysSinceLastMention(topic: "  ") == nil)

        try store.append(sessionId: sid, message: .user("hoy toqué GUITARRA un rato"))
        try store.append(sessionId: sid, message: .assistant([.text("¡guitarra! qué bien")]))
        try store.append(sessionId: sid, message: .user("ensayé con 100% de ganas"))
        try queue.write { db in
            try db.execute(sql: "UPDATE turn_event SET created_at=? WHERE seq=1", arguments: [now.timeIntervalSince1970 - 3 * 86_400 - 60])
            try db.execute(sql: "UPDATE turn_event SET created_at=? WHERE seq=2", arguments: [now.timeIntervalSince1970])
            try db.execute(sql: "UPDATE turn_event SET created_at=? WHERE seq=3", arguments: [now.timeIntervalSince1970 - 86_400])
        }
        #expect(index.daysSinceLastMention(topic: "guitarra") == 3)     // solo cuenta el dueño
        #expect(index.daysSinceLastMention(topic: "100%") == 1)
        #expect(index.daysSinceLastMention(topic: "1_0") == nil)        // _ no es comodín
        #expect(index.daysSinceLastMention(topic: "piano") == nil)
    }

    @Test func systemEnvironmentAnswersFromTheDatabase() async throws {
        let queue = try AnimaDatabase.temporary()
        let other = OtherModel(queue: queue)
        let id = await other.ingestStated(statement: "x", desiredState: .progressCheckIn(everyDays: 2), evidence: "")
        await other.recordCheckIn(goalId: id, answer: .yes)
        let env = SystemObservableEnvironment(otherModel: other, mentions: MentionIndex(queue: queue))
        #expect(await env.daysSinceProgress(goalId: id) == 0)
        #expect(await env.daysSinceLastMention(topic: "nada") == nil)
        let bare = SystemObservableEnvironment()
        #expect(await bare.daysSinceProgress(goalId: id) == nil)
        #expect(await bare.daysSinceLastMention(topic: "x") == nil)
    }
}

@Suite struct CheckInSchedulerTests {
    typealias F = ProactiveFixtures

    private func goal(_ cadence: CheckInCadence, status: GoalStatus = .active,
                      source: GoalSource = .stated) -> Goal {
        Goal(id: "g1", statement: "invertir 10M", desiredState: .progressCheckIn(everyDays: 2), source: source,
             status: status, priority: 5, evidence: "", confirmedByOther: false, createdAt: F.start,
             updatedAt: F.start, checkIn: cadence)
    }

    @Test func idsAndCountPerCadence() throws {
        let daily = CheckInScheduler.requests(for: goal(CheckInCadence(cadence: .daily, hour: 20)), title: "Lumen")
        #expect(daily.map(\.id) == ["anima-checkin-g1"])
        var expected = DateComponents()
        expected.hour = 20
        expected.minute = 0
        #expect(daily.first?.trigger == .calendar(expected, repeats: true))
        #expect(daily.first?.body == "¿Cómo vas con invertir 10M?")
        #expect(daily.first?.title == "Lumen")
        #expect(daily.first?.categoryId == ProactiveNotificationIDs.checkInCategory)
        #expect(daily.first?.deepLink == AnimaDeepLink.goal(id: "g1").url)

        let weekdays = CheckInScheduler.requests(for: goal(CheckInCadence(cadence: .weekdays, hour: 7)), title: "A")
        #expect(weekdays.map(\.id) == (2...6).map { "anima-checkin-g1-\($0)" })

        let weekly = CheckInScheduler.requests(for: goal(CheckInCadence(cadence: .weekly, hour: 9, weekday: 1)), title: "A")
        expected.hour = 9
        expected.weekday = 1
        #expect(weekly.map(\.id) == ["anima-checkin-g1"])
        #expect(weekly.first?.trigger == .calendar(expected, repeats: true))

        #expect(CheckInScheduler.requests(for: goal(.off), title: "A").isEmpty)
        #expect(CheckInScheduler.requests(for: goal(CheckInCadence(cadence: .daily), status: .abandoned), title: "A").isEmpty)
        #expect(CheckInScheduler.requests(for: goal(CheckInCadence(cadence: .daily), source: .inferred), title: "A").isEmpty)
        #expect(CheckInScheduler.requests(for: goal(CheckInCadence(cadence: .weekly, weekday: nil)), title: "A").isEmpty)
        #expect(CheckInScheduler.chatPrompt(for: goal(.off)) == "¿Cómo vas con invertir 10M? Cuéntame y lo anoto.")
    }

    @Test func syncIsIdempotentAndCancelsOnAbandonOrAchieve() async throws {
        let w = try F.world()
        let a = await w.other.ingestStated(statement: "invertir", desiredState: .progressCheckIn(everyDays: 2), evidence: "")
        let b = await w.other.ingestStated(statement: "correr", desiredState: .progressCheckIn(everyDays: 2), evidence: "")
        await w.other.setCheckIn(id: a, CheckInCadence(cadence: .daily))
        await w.other.setCheckIn(id: b, CheckInCadence(cadence: .weekdays, hour: 6))
        let first = Set(await w.scheduler.sync())
        #expect(first.count == 6)
        let snapshot = w.fake.scheduled
        #expect(Set(await w.scheduler.sync()) == first)
        #expect(w.fake.scheduled == snapshot)

        await w.other.abandon(id: b)
        #expect(await w.scheduler.sync() == ["anima-checkin-\(a)"])
        #expect(await w.fake.pendingIds() == ["anima-checkin-\(a)"])
        await w.other.markAchieved(id: a)
        #expect(await w.scheduler.sync().isEmpty)
        #expect(await w.fake.pendingIds().isEmpty)
    }
}

@Suite struct CheckInPromptTests {
    typealias F = ProactiveFixtures

    @Test func promptPersistsOnceAndRespectsAnswers() async throws {
        let w = try F.world()
        let sid = try w.symbolic.startSession()
        let id = await w.other.ingestStated(statement: "invertir 10M", desiredState: .progressCheckIn(everyDays: 2),
                                            evidence: "")
        #expect(await w.reconciler.checkInPrompt(goalId: "nope", sessionId: sid) == nil)
        let first = try #require(await w.reconciler.checkInPrompt(goalId: id, sessionId: sid))
        #expect(first == ProactiveMessage(kind: .checkIn(goalId: id), text: "¿Cómo vas con invertir 10M? Cuéntame y lo anoto."))
        let again = await w.reconciler.checkInPrompt(goalId: id, sessionId: sid)
        #expect(again == first)
        #expect(try w.symbolic.visibleTurns(sessionId: sid).count == 1)   // no se duplica en el transcript
        #expect(await w.other.checkIns(goalId: id).count == 1)

        await w.other.recordCheckIn(goalId: id, answer: .yes)              // contestó (acción o chat)
        #expect(await w.reconciler.checkInPrompt(goalId: id, sessionId: sid) == nil)

        w.clock.mutate { $0 = F.date(2026, 10, 6, 20) }
        #expect(await w.reconciler.checkInPrompt(goalId: id, sessionId: sid) != nil)
        await w.other.abandon(id: id)
        w.clock.mutate { $0 = F.date(2026, 10, 7, 20) }
        #expect(await w.reconciler.checkInPrompt(goalId: id, sessionId: sid) == nil)
    }
}

@Suite struct GoalsToolTests {
    typealias F = ProactiveFixtures

    private func tool(_ w: F.World, changes: Locked<Int> = Locked(0)) -> GoalsTool {
        GoalsTool(otherModel: w.other, onChange: { changes.mutate { $0 += 1 } })
    }

    @Test func specKindsAndSummaries() throws {
        let w = try F.world()
        let t = tool(w)
        #expect(t.spec.name == "goals")
        #expect(t.spec.descriptionText.contains("regístrala YA"))
        #expect(t.kind(for: ["action": "list"]) == .afferent)
        #expect(t.kind(for: ["action": "record_checkin"]) == .afferent)
        for action in ["declare", "set_checkin", "clear_checkin", "mark_achieved"] {
            #expect(t.kind(for: ["action": .string(action)]) == .efferent)
        }
        #expect(t.confirmationSummary(for: ["action": "declare", "statement": "invertir 10M",
                                            "checkin": ["cadence": "daily", "hour": 20]])
                == "Registrar meta 'invertir 10M' y preguntarte cada día a las 20:00")
        #expect(t.confirmationSummary(for: ["action": "declare", "statement": "x"]) == "Registrar meta 'x'")
        #expect(t.confirmationSummary(for: ["action": "set_checkin", "goal_id": "g", "cadence": "weekly",
                                            "weekday": 6, "hour": 9])
                == "Preguntarte por la meta g cada viernes a las 09:00")
        #expect(t.confirmationSummary(for: ["action": "set_checkin", "goal_id": "g", "cadence": "none"])
                == "Quitar el check-in de la meta g")
        #expect(t.confirmationSummary(for: ["action": "clear_checkin", "goal_id": "g"]) == "Quitar el check-in de la meta g")
        #expect(t.confirmationSummary(for: ["action": "mark_achieved", "goal_id": "g"]) == "Marcar como lograda la meta g")
        #expect(t.confirmationSummary(for: ["action": "list"]) == "goals: list")
    }

    @Test func declareWithCheckInThenLifecycle() async throws {
        let w = try F.world()
        let changes = Locked(0)
        let t = tool(w, changes: changes)
        #expect(await t.execute(["action": "list"]).content.contains("no tiene metas"))

        let declared = await t.execute(["action": "declare", "statement": "Invertir 10M este año",
                                        "checkin": ["cadence": "daily", "hour": 21, "minute": 30]])
        #expect(!declared.isError && declared.content.contains("cada día a las 21:30"))
        let goal = try #require(await w.other.allGoals().first)
        #expect(goal.source == .stated && goal.status == .active)
        #expect(goal.desiredState == .progressCheckIn(everyDays: 2))
        #expect(goal.checkIn == CheckInCadence(cadence: .daily, hour: 21, minute: 30))
        #expect(changes.value == 1)

        let gid = JSONValue.string(goal.id)
        #expect(!(await t.execute(["action": "set_checkin", "goal_id": gid, "cadence": "weekly", "weekday": "6"])).isError)
        #expect(await w.other.goal(id: goal.id)?.checkIn == CheckInCadence(cadence: .weekly, hour: 20, weekday: 6))
        let recorded = await t.execute(["action": "record_checkin", "goal_id": gid, "answer": "yes", "note": "1M"])
        #expect(recorded.content == "Check-in anotado (yes). Racha: 1 días.")
        let listed = await t.execute(["action": "list"])
        #expect(listed.content.contains("[\(goal.id)] Invertir 10M este año"))
        #expect(listed.content.contains("check-in cada viernes a las 20:00"))
        #expect(listed.content.contains("racha 1 días") && listed.content.contains("último check-in: yes — 1M"))
        #expect(await t.execute(["action": "clear_checkin", "goal_id": gid]).content == "Check-in quitado.")
        #expect(await t.execute(["action": "set_checkin", "goal_id": gid, "cadence": "none"]).content == "Check-in quitado.")
        #expect(await t.execute(["action": "mark_achieved", "goal_id": gid]).content == "Meta marcada como lograda.")
        #expect(await w.other.goal(id: goal.id)?.status == .achieved)
        #expect(changes.value == 5)
    }

    @Test func declareWithExplicitPredicateAndWeeklyDefault() async throws {
        let w = try F.world()
        let t = tool(w)
        _ = await t.execute(["action": "declare", "statement": "entrenar",
                             "predicate": ["kind": "workouts_per_week", "value": 3],
                             "checkin": ["cadence": "weekly", "hour": 8.0]])
        let goal = try #require(await w.other.allGoals().first)
        #expect(goal.desiredState == .workoutsPerWeek(atLeast: 3))
        #expect(goal.checkIn == CheckInCadence(cadence: .weekly, hour: 8, weekday: 2))
        _ = await t.execute(["action": "declare", "statement": "leer"])
        #expect(await w.other.allGoals().first { $0.statement == "leer" }?.desiredState == .progressCheckIn(everyDays: 7))
        #expect(GoalsTool.defaultEveryDays(.weekly) == 8 && GoalsTool.defaultEveryDays(.weekdays) == 2)
    }

    @Test func errors() async throws {
        let w = try F.world()
        let t = tool(w)
        #expect(await t.execute([:]).isError)
        #expect(await t.execute(["action": "boom"]).content.contains("desconocida"))
        #expect(await t.execute(["action": "declare"]).content.contains("statement"))
        #expect(await t.execute(["action": "declare", "statement": "x", "predicate": ["kind": "magic"]])
            .content.contains("vocabulario cerrado"))
        #expect(await t.execute(["action": "declare", "statement": "x", "checkin": ["cadence": "hourly"]])
            .content.contains("check-in inválido"))
        #expect(await t.execute(["action": "declare", "statement": "x", "checkin": ["cadence": "daily", "hour": 25]])
            .content.contains("check-in inválido"))
        for action in ["set_checkin", "clear_checkin", "record_checkin", "mark_achieved"] {
            #expect(await t.execute(["action": .string(action)]).content.contains("goal_id"))
        }
        #expect(await t.execute(["action": "set_checkin", "goal_id": "g"]).content.contains("check-in inválido"))
        #expect(await t.execute(["action": "set_checkin", "goal_id": "g", "cadence": "daily"]) == GoalsTool.notFound)
        #expect(await t.execute(["action": "clear_checkin", "goal_id": "g"]) == GoalsTool.notFound)
        #expect(await t.execute(["action": "record_checkin", "goal_id": "g", "answer": "maybe"]).content.contains("answer"))
        #expect(await t.execute(["action": "record_checkin", "goal_id": "g", "answer": "yes"]) == GoalsTool.notFound)
        #expect(await t.execute(["action": "mark_achieved", "goal_id": "g"]) == GoalsTool.notFound)
        #expect(GoalsTool.int(.bool(true)) == nil)
    }
}
