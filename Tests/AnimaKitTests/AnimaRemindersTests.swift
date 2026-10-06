import Foundation
import Testing
import GRDB
@testable import AnimaKit

extension ToolSpec {
    var descriptionText: String {
        if case .client(_, let description, _) = self { return description }
        return ""
    }
}

// Literales de JSONValue para inputs de tools legibles en los tests.
extension JSONValue: ExpressibleByDictionaryLiteral, ExpressibleByStringLiteral,
                     ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
}

/// Reloj/calendario fijos de la capa proactiva: Bogotá, lunes 5-oct-2026 14:30.
enum ProactiveFixtures {
    static let tz = TimeZone(identifier: "America/Bogota")!
    static let start = Date(timeIntervalSince1970: 1_791_228_600)
    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        cal.locale = Locale(identifier: "es_CO")
        return cal
    }

    /// Fecha local de Bogotá.
    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    struct World {
        let queue: DatabaseQueue
        let clock: Locked<Date>
        let reminders: AnimaReminderStore
        let other: OtherModel
        let symbolic: SymbolicStore
        let fake: FakeNotificationScheduler
        let scheduler: ProactiveScheduler
        let reconciler: ProactiveReconciler

        func advance(_ seconds: TimeInterval) { clock.mutate { $0 = $0.addingTimeInterval(seconds) } }
    }

    static func world(status: NotificationAuthorization = .notDetermined, maxPending: Int = 60) throws -> World {
        let queue = try AnimaDatabase.temporary()
        let clock = Locked(start)
        let now: @Sendable () -> Date = { clock.value }
        let reminders = AnimaReminderStore(queue: queue, calendar: calendar, now: now)
        let other = OtherModel(queue: queue, calendar: calendar, now: now)
        let symbolic = SymbolicStore(queue: queue)
        let fake = FakeNotificationScheduler(status: status)
        let scheduler = ProactiveScheduler(scheduler: fake, reminders: reminders, otherModel: other,
                                           selfName: { "Lumen" }, calendar: calendar, maxPending: maxPending)
        let reconciler = ProactiveReconciler(reminders: reminders, otherModel: other, store: symbolic,
                                             calendar: calendar, now: now)
        return World(queue: queue, clock: clock, reminders: reminders, other: other, symbolic: symbolic,
                     fake: fake, scheduler: scheduler, reconciler: reconciler)
    }
}

@Suite struct AnimaReminderStoreTests {
    typealias F = ProactiveFixtures

    @Test func createValidatesAndLists() async throws {
        let w = try F.world()
        await #expect(throws: AnimaReminderError.emptyText) {
            try await w.reminders.create(text: "   ", fireAt: F.date(2026, 10, 6, 9))
        }
        await #expect(throws: AnimaReminderError.pastFireAt) {
            try await w.reminders.create(text: "x", fireAt: F.date(2026, 10, 5, 9))
        }
        await #expect(throws: AnimaReminderError.unknownGoal) {
            try await w.reminders.create(text: "x", fireAt: F.date(2026, 10, 6, 9), goalId: "nope")
        }
        let r = try await w.reminders.create(text: " llamar al banco ", fireAt: F.date(2026, 10, 6, 9),
                                             originSessionId: "s1")
        #expect(r.text == "llamar al banco")
        #expect(r.status == .scheduled && r.originSessionId == "s1")
        #expect(await w.reminders.list(.upcoming).map(\.id) == [r.id])
        #expect(await w.reminders.list(.all).count == 1)
        #expect(await w.reminders.list(.fired).isEmpty)
        #expect(await w.reminders.scheduledCount() == 1)
        #expect(await w.reminders.reminder(id: r.id) == r)
        #expect(await w.reminders.reminder(id: "nope") == nil)
    }

    @Test func dueNowMarkFiredCompleteAndCancel() async throws {
        let w = try F.world()
        let a = try await w.reminders.create(text: "a", fireAt: F.date(2026, 10, 5, 15))
        let b = try await w.reminders.create(text: "b", fireAt: F.date(2026, 10, 7, 9))
        #expect(await w.reminders.dueNow().isEmpty)
        w.advance(3600)
        #expect(await w.reminders.dueNow().map(\.id) == [a.id])
        #expect(await w.reminders.dueNow(now: F.date(2026, 10, 8, 0)).map(\.id) == [a.id, b.id])

        let fired = try #require(await w.reminders.markFired(id: a.id))
        #expect(fired.status == .fired && fired.firedAt != nil)
        #expect(await w.reminders.markFired(id: a.id) == nil)          // ya entregado
        #expect(await w.reminders.dueNow().isEmpty)
        #expect(await w.reminders.list(.fired).map(\.id) == [a.id])

        let done = try await w.reminders.complete(id: a.id)
        #expect(done.status == .done && done.doneAt != nil)
        await #expect(throws: AnimaReminderError.notActive) { try await w.reminders.complete(id: a.id) }
        await #expect(throws: AnimaReminderError.notFound) { try await w.reminders.cancel(id: "nope") }

        let cancelled = try await w.reminders.cancel(id: b.id)
        #expect(cancelled.status == .cancelled)
        #expect(await w.reminders.scheduledCount() == 0)
    }

    @Test func snoozeMovesOneOffAndForksRepeating() async throws {
        let w = try F.world()
        let once = try await w.reminders.create(text: "agua", fireAt: F.date(2026, 10, 5, 15))
        await #expect(throws: AnimaReminderError.invalidMinutes) { try await w.reminders.snooze(id: once.id, minutes: 0) }
        w.advance(3600)
        _ = await w.reminders.markFired(id: once.id)
        let moved = try await w.reminders.snooze(id: once.id, minutes: 60)
        #expect(moved.id == once.id && moved.status == .scheduled)
        #expect(moved.fireAt == F.start.addingTimeInterval(7200))

        let daily = try await w.reminders.create(text: "vitaminas", fireAt: F.date(2026, 10, 6, 8), repeat: .daily)
        let fork = try await w.reminders.snooze(id: daily.id, minutes: 30)
        #expect(fork.id != daily.id && fork.repeatCadence == .none && fork.text == "vitaminas")
        #expect(await w.reminders.reminder(id: daily.id)?.fireAt == F.date(2026, 10, 6, 8))
    }

    @Test func repeatingAdvancesOnFireAndCompleteKeepsSeries() async throws {
        let w = try F.world()
        let daily = try await w.reminders.create(text: "meditar", fireAt: F.date(2026, 10, 5, 21), repeat: .daily)
        w.clock.mutate { $0 = F.date(2026, 10, 7, 10) }   // dos días sin abrir la app
        #expect(await w.reminders.dueNow().map(\.id) == [daily.id])
        let advanced = try #require(await w.reminders.markFired(id: daily.id))
        #expect(advanced.status == .scheduled)
        #expect(advanced.fireAt == F.date(2026, 10, 7, 21))
        #expect(await w.reminders.dueNow().isEmpty)
        let done = try await w.reminders.complete(id: daily.id)
        #expect(done.status == .scheduled && done.doneAt != nil)
    }

    @Test func nextOccurrenceByCadence() {
        let cal = F.calendar
        let monday9 = F.date(2026, 10, 5, 9)        // lunes
        let friday10 = F.date(2026, 10, 9, 10)      // viernes
        #expect(AnimaReminderStore.nextOccurrence(after: monday9, of: monday9, repeat: .none, calendar: cal) == nil)
        #expect(AnimaReminderStore.nextOccurrence(after: monday9, of: monday9, repeat: .daily, calendar: cal)
                == F.date(2026, 10, 6, 9))
        #expect(AnimaReminderStore.nextOccurrence(after: monday9, of: monday9, repeat: .weekly, calendar: cal)
                == F.date(2026, 10, 12, 9))
        #expect(AnimaReminderStore.nextOccurrence(after: friday10, of: monday9, repeat: .weekdays, calendar: cal)
                == F.date(2026, 10, 12, 9))         // salta el fin de semana
        #expect(AnimaReminderStore.nextOccurrence(after: monday9, of: monday9, repeat: .weekdays, calendar: cal)
                == F.date(2026, 10, 6, 9))
    }

    @Test func occurrencesOnlyForScheduled() async throws {
        let w = try F.world()
        let weekly = try await w.reminders.create(text: "x", fireAt: F.date(2026, 10, 6, 9), repeat: .weekly)
        let dates = AnimaReminderStore.occurrences(of: weekly, count: 3, calendar: F.calendar)
        #expect(dates == [F.date(2026, 10, 6, 9), F.date(2026, 10, 13, 9), F.date(2026, 10, 20, 9)])
        let cancelled = try await w.reminders.cancel(id: weekly.id)
        #expect(AnimaReminderStore.occurrences(of: cancelled, count: 3, calendar: F.calendar).isEmpty)
    }

    @Test func cadencePhrasesAndErrorDescriptions() {
        #expect(ProactiveCadence.none.phrase == nil)
        #expect(ProactiveCadence.daily.phrase == "cada día")
        #expect(ProactiveCadence.weekdays.phrase == "entre semana")
        #expect(ProactiveCadence.weekly.phrase == "cada semana")
        let all: [AnimaReminderError] = [.emptyText, .pastFireAt, .notFound, .notActive, .unknownGoal, .invalidMinutes]
        #expect(Set(all.compactMap(\.errorDescription)).count == all.count)
    }
}

@Suite struct AnimaRemindersToolTests {
    typealias F = ProactiveFixtures

    private func tool(_ w: F.World, changes: Locked<Int> = Locked(0)) -> AnimaRemindersTool {
        AnimaRemindersTool(store: w.reminders, timeZone: F.tz, onChange: { changes.mutate { $0 += 1 } })
    }

    @Test func specSaysPersonalAndRoutesAgendaElsewhere() throws {
        let w = try F.world()
        let spec = tool(w).spec
        #expect(spec.name == "anima_reminders")
        let description = spec.descriptionText
        #expect(description.contains("PERSONALES de Anima"))
        #expect(description.contains("recuérdame"))
        #expect(description.contains("`calendar`") && description.contains("`reminders`"))
        #expect(RemindersTool().spec.descriptionText.contains("anima_reminders"))
        #expect(CalendarTool().spec.descriptionText.contains("anima_reminders"))
    }

    @Test func kindsAndSummaries() throws {
        let w = try F.world()
        let t = tool(w)
        #expect(t.kind(for: ["action": "list"]) == .afferent)
        for action in ["create", "complete", "cancel", "snooze", "bogus"] {
            #expect(t.kind(for: ["action": .string(action)]) == .efferent)
        }
        #expect(t.confirmationSummary(for: ["action": "create", "text": "llamar al banco",
                                            "fire_at": "2026-10-06T09:00:00-05:00"])
                == "Recordarte 'llamar al banco' el martes 6 de octubre a las 09:00")
        #expect(t.confirmationSummary(for: ["action": "create", "text": "x", "fire_at": "2026-10-06T09:00:00-05:00",
                                            "repeat": "daily"]).hasSuffix("(cada día)"))
        #expect(t.confirmationSummary(for: ["action": "create", "text": "x", "fire_at": "mañana"])
                == "Recordarte 'x' el mañana")
        #expect(t.confirmationSummary(for: ["action": "complete", "id": "r1"]) == "Marcar como hecho el recordatorio r1")
        #expect(t.confirmationSummary(for: ["action": "cancel", "id": "r1"]) == "Cancelar el recordatorio r1")
        #expect(t.confirmationSummary(for: ["action": "snooze", "id": "r1", "minutes": 60]) == "Posponer 60 min el recordatorio r1")
        #expect(t.confirmationSummary(for: ["action": "list"]) == "anima_reminders: list")
    }

    @Test func createWithOffsetListAndLifecycle() async throws {
        let w = try F.world()
        let changes = Locked(0)
        let t = tool(w, changes: changes)
        #expect(await t.execute(["action": "list"]).content == "No tienes recordatorios de Anima.")

        // 09:00 en Ciudad de México (-06:00) = 10:00 en Bogotá.
        let created = await t.execute(["action": "create", "text": "llamar al banco",
                                       "fire_at": "2026-10-06T09:00:00-06:00"])
        #expect(!created.isError)
        #expect(created.content.contains("martes 6 de octubre a las 10:00"))
        let r = try #require(await w.reminders.list(.upcoming).first)
        #expect(r.fireAt == F.date(2026, 10, 6, 10))
        #expect(changes.value == 1)

        let fractional = await t.execute(["action": "create", "text": "agua", "repeat": "weekdays",
                                          "fire_at": "2026-10-06T08:00:00.000-05:00"])
        #expect(fractional.content.contains("(entre semana)"))

        let listed = await t.execute(["action": "list"])
        #expect(listed.content.contains("Programados:") && listed.content.contains("[\(r.id)] llamar al banco"))
        #expect(listed.content.contains("entre semana"))

        #expect(!(await t.execute(["action": "snooze", "id": .string(r.id), "minutes": 30])).isError)
        #expect(!(await t.execute(["action": "snooze", "id": .string(r.id), "minutes": 30.0])).isError)
        #expect(!(await t.execute(["action": "snooze", "id": .string(r.id), "minutes": "15"])).isError)
        #expect(await t.execute(["action": "snooze", "id": .string(r.id)]).isError)
        #expect(!(await t.execute(["action": "complete", "id": .string(r.id)])).isError)
        let again = await t.execute(["action": "complete", "id": .string(r.id)])
        #expect(again.isError && again.content.contains("cerrado"))
        let other = try #require(await w.reminders.list(.upcoming).first)
        #expect(!(await t.execute(["action": "cancel", "id": .string(other.id)])).isError)
        #expect(changes.value == 7)
    }

    @Test func createStoresHerMessageAndSnoozeKeepsIt() async throws {
        let w = try F.world()
        let t = tool(w)
        #expect(t.spec.descriptionText.contains("`message` es OBLIGATORIO"))
        #expect(t.confirmationSummary(for: ["action": "create", "text": "cita", "message": "Oye, ya casi es tu cita",
                                            "fire_at": "2026-10-06T09:00:00-05:00"])
                .hasSuffix("Te diré: «Oye, ya casi es tu cita»"))
        let created = await t.execute(["action": "create", "text": "cita médica", "repeat": "daily",
                                       "message": "Oye, en media hora tienes la cita médica",
                                       "fire_at": "2026-10-06T08:00:00-05:00"])
        #expect(created.content.contains("te diré: «Oye, en media hora tienes la cita médica»"))
        let r = try #require(await w.reminders.list(.upcoming).first)
        #expect(r.message == "Oye, en media hora tienes la cita médica")
        let fork = try await w.reminders.snooze(id: r.id, minutes: 10)
        #expect(fork.message == r.message)
        let fallback = await t.execute(["action": "create", "text": "agua", "fire_at": "2026-10-06T10:00:00-05:00"])
        #expect(fallback.content.contains("te diré: «Te recuerdo: agua»"))
    }

    @Test func listShowsFiredAndGoal() async throws {
        let w = try F.world()
        let goalId = await w.other.ingestStated(statement: "ahorrar", desiredState: .remindersOverdue(atMost: 0),
                                                evidence: "")
        let t = tool(w)
        _ = await t.execute(["action": "create", "text": "transferir", "fire_at": "2026-10-05T15:00:00-05:00",
                             "goal_id": .string(goalId)])
        w.advance(3600)
        for r in await w.reminders.dueNow() { _ = await w.reminders.markFired(id: r.id) }
        let listed = await t.execute(["action": "list"])
        #expect(listed.content.contains("Ya entregados"))
        #expect(listed.content.contains("meta \(goalId)"))
    }

    @Test func validationErrors() async throws {
        let w = try F.world()
        let t = tool(w)
        #expect(await t.execute([:]).isError)
        #expect(await t.execute(["action": "explode"]).content.contains("desconocida"))
        let past = await t.execute(["action": "create", "text": "x", "fire_at": "2026-10-05T09:00:00-05:00"])
        #expect(past.isError && past.content.contains("ya pasó"))
        let dateOnly = await t.execute(["action": "create", "text": "x", "fire_at": "2026-10-06"])
        #expect(dateOnly.isError && dateOnly.content.contains("ISO 8601"))
        let empty = await t.execute(["action": "create", "text": "", "fire_at": "2026-10-06T09:00:00-05:00"])
        #expect(empty.isError && empty.content.contains("vacío"))
        let missing = await t.execute(["action": "create", "text": "x"])
        #expect(missing.isError && missing.content.contains("fire_at"))
        let badRepeat = await t.execute(["action": "create", "text": "x", "fire_at": "2026-10-06T09:00:00-05:00",
                                         "repeat": "hourly"])
        #expect(badRepeat.isError && badRepeat.content.contains("repeat"))
        #expect(await t.execute(["action": "cancel"]).content.contains("falta 'id'"))
    }

    /// Mismo parser que calendar/reminders: con offset, sin offset (hora local) y con fracción.
    @Test func fireAtAcceptsTheSameISOFormsAsTheAgenda() async throws {
        let w = try F.world()
        let t = tool(w)
        let nine = F.date(2026, 10, 6, 9)
        for raw in ["2026-10-06T09:00:00-05:00", "2026-10-06T09:00:00", "2026-10-06T09:00:00.000-05:00",
                    "2026-10-06T14:00:00Z", "2026-10-06T09:00"] {
            #expect(AnimaRemindersTool.parseDate(raw, timeZone: F.tz) == nine, "\(raw)")
        }
        let local = await t.execute(["action": "create", "text": "llamar al banco", "message": "Oye, llama al banco",
                                     "fire_at": "2026-10-06T09:00:00"])
        #expect(!local.isError, "\(local.content)")
        #expect(await w.reminders.list().first?.fireAt == nine)
        #expect(t.confirmationSummary(for: ["action": "create", "text": "x", "fire_at": "2026-10-06T09:00:00"])
                    .contains("martes 6 de octubre a las 09:00"))
        #expect(AnimaRemindersTool.parseDate("mañana", timeZone: F.tz) == nil)
    }
}

@Suite struct ProactiveSchedulerReminderTests {
    typealias F = ProactiveFixtures

    @Test func syncSchedulesRemindersAsksPermissionOnceAndIsIdempotent() async throws {
        let w = try F.world()
        #expect(await w.scheduler.sync().isEmpty)
        #expect(w.fake.requestCount == 0)                 // nada que entregar ⇒ sin pedir permiso

        let r = try await w.reminders.create(text: "llamar al banco", fireAt: F.date(2026, 10, 6, 9))
        let ids = await w.scheduler.sync()
        #expect(ids == ["anima-reminder-\(r.id)"])
        #expect(w.fake.requestCount == 1)
        let request = try #require(w.fake.scheduled["anima-reminder-\(r.id)"])
        #expect(request.title == "Lumen" && request.body == "Te recuerdo: llamar al banco")
        #expect(request.categoryId == ProactiveNotificationIDs.reminderCategory)
        #expect(request.trigger == .at(F.date(2026, 10, 6, 9)))
        #expect(request.userInfo[ProactiveNotificationIDs.linkKey] == "anima://reminder?id=\(r.id)")

        let before = w.fake.scheduled
        _ = await w.scheduler.sync()
        #expect(w.fake.scheduled == before)
        #expect(w.fake.requestCount == 1)

        _ = try await w.reminders.cancel(id: r.id)
        await w.fake.schedule(LocalNotificationRequest(id: "handoff-x", title: "", body: "", trigger: .immediate,
                                                       categoryId: "", deepLink: nil))
        _ = await w.scheduler.sync()
        #expect(await w.fake.pendingIds() == ["handoff-x"])   // no toca lo ajeno
    }

    @Test func pushSpeaksInHerVoice() async throws {
        let w = try F.world(status: .granted)
        let r = try await w.reminders.create(text: "cita médica", message: " Oye, en media hora tienes la cita médica ",
                                             fireAt: F.date(2026, 10, 6, 8))
        _ = await w.scheduler.sync()
        let request = try #require(w.fake.scheduled["anima-reminder-\(r.id)"])
        #expect(request.title == "Lumen")
        #expect(request.body == "Oye, en media hora tienes la cita médica")
        let blank = try await w.reminders.create(text: "agua", message: "  ", fireAt: F.date(2026, 10, 6, 9))
        #expect(blank.message == nil && blank.spokenMessage == "Te recuerdo: agua")
    }

    @Test func repeatingSchedulesNextOccurrencesAndCapsAtMax() async throws {
        let w = try F.world(maxPending: 10)
        let daily = try await w.reminders.create(text: "agua", fireAt: F.date(2026, 10, 6, 8), repeat: .daily)
        for day in 6...12 {
            _ = try await w.reminders.create(text: "uno \(day)", fireAt: F.date(2026, 10, day, 12))
        }
        let ids = await w.scheduler.sync()
        #expect(ids.count == 10)
        #expect(ids.contains("anima-reminder-\(daily.id)") && ids.contains("anima-reminder-\(daily.id)-4"))
        #expect(!ids.contains("anima-reminder-\(daily.id)-5"))   // la más lejana queda fuera del tope
    }

    @Test func notifyIntentionIsImmediateWithDeepLink() async throws {
        let w = try F.world(status: .granted)
        let intention = Intention(id: "i1", goalId: "g", observablesJSON: "{}", gap: "", proposedText: "¿Salimos a correr?",
                                  outcome: .pending, createdAt: F.start)
        await w.scheduler.notify(intention)
        let request = try #require(w.fake.scheduled["anima-intention-i1"])
        #expect(request.trigger == .immediate && request.body == "¿Salimos a correr?")
        #expect(request.categoryId == ProactiveNotificationIDs.intentionCategory)
        #expect(request.deepLink == AnimaDeepLink.intention(id: "i1").url)
    }

    @Test func fakeSchedulerDeniedStaysDenied() async {
        let fake = FakeNotificationScheduler(status: .notDetermined, grantOnRequest: false)
        #expect(await fake.requestAuthorization() == false)
        #expect(await fake.authorizationStatus() == .denied)
        #expect(await fake.requestAuthorization() == false)
        #expect(fake.requestCount == 1)
    }
}

@Suite struct ProactiveReconcilerTests {
    typealias F = ProactiveFixtures

    @Test func dueReminderBecomesProactiveMessageOnce() async throws {
        let w = try F.world()
        let sid = try w.symbolic.startSession()
        let goalId = await w.other.ingestStated(statement: "invertir 10M este año",
                                                desiredState: .remindersOverdue(atMost: 0), evidence: "")
        let plain = try await w.reminders.create(text: "llamar al banco", fireAt: F.date(2026, 10, 5, 15))
        let linked = try await w.reminders.create(text: "revisar el CDT", fireAt: F.date(2026, 10, 5, 15, 5),
                                                  goalId: goalId)
        #expect(await w.reconciler.reconcileDueReminders(sessionId: sid).isEmpty)

        w.advance(2 * 3600)
        let messages = await w.reconciler.reconcileDueReminders(sessionId: sid)
        #expect(messages == [
            ProactiveMessage(kind: .reminder(id: plain.id), text: "Te recuerdo: llamar al banco",
                             at: F.date(2026, 10, 5, 15)),
            ProactiveMessage(kind: .reminder(id: linked.id), text: "Te recuerdo: revisar el CDT",
                             at: F.date(2026, 10, 5, 15, 5), goalStatement: "invertir 10M este año"),
        ])
        #expect(await w.reconciler.reconcileDueReminders(sessionId: sid).isEmpty)   // sin duplicar
        let turns = try w.symbolic.visibleTurns(sessionId: sid)
        #expect(turns.map(\.text) == messages.map(\.text))
        #expect(turns.allSatisfy { $0.role == .assistant })
        #expect(turns.map(\.proactive) == messages.map(\.tag))
        #expect(await w.reminders.reminder(id: plain.id)?.status == .fired)
    }

    @Test func withoutSessionDoesNotPersist() async throws {
        let w = try F.world()
        _ = try await w.reminders.create(text: "x", fireAt: F.date(2026, 10, 5, 15))
        w.advance(2 * 3600)
        #expect(await w.reconciler.reconcileDueReminders(sessionId: nil).count == 1)
    }
}

@Suite struct ProactiveDeepLinkTests {
    @Test func roundTripsNewLinks() throws {
        let links: [AnimaDeepLink] = [.reminder(id: "r-1"), .goal(id: "g 2"), .intention(id: "i3"),
                                      .chat(turn: nil), .glasses]
        for link in links {
            #expect(AnimaDeepLink.parse(link.url) == link)
        }
        #expect(AnimaDeepLink.reminder(id: "abc").url.absoluteString == "anima://reminder?id=abc")
        #expect(AnimaDeepLink.goal(id: "g").url.absoluteString == "anima://goal?id=g")
        #expect(AnimaDeepLink.intention(id: "i").url.absoluteString == "anima://intention?id=i")
    }

    @Test func rejectsMissingIdOrUnknownHost() throws {
        for raw in ["anima://reminder", "anima://goal?id=", "anima://intention?x=1", "anima://nope?id=1",
                    "https://reminder?id=1"] {
            #expect(AnimaDeepLink.parse(URL(string: raw)!) == nil)
        }
        #expect(AnimaDeepLink.parse(URL(string: "ANIMA://Reminder?id=X")!) == .reminder(id: "X"))
    }
}

@Suite struct ReminderSignatureNameTests {
    @Test func nameComesFromIdentity() async throws {
        #expect(SelfView.name(fromIdentity: "Eres Lumen, un asistente personal.") == "Lumen")
        #expect(SelfView.name(fromIdentity: "Eres Nova. Existo para ti") == "Nova")
        #expect(SelfView.name(fromIdentity: "Asistente sin nombre") == nil)
        #expect(SelfView.name(fromIdentity: "Eres , nada") == nil)
        let model = SelfModel(queue: try AnimaDatabase.temporary(),
                              birth: Birth(name: "Kai", tone: "x", language: "es"))
        #expect(await model.name() == "Kai")
    }
}
