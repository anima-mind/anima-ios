import Foundation
import Testing
import GRDB
@testable import AnimaKit
@testable import AnimaWidgetCore

/// Botones de los widgets: cola durable en el App Group + el MISMO handler de
/// las notificaciones + repintado optimista.
@Suite struct WidgetActionInboxTests {

    static func inbox() -> WidgetActionInbox {
        WidgetActionInbox(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("winbox-\(UUID().uuidString)/Actions"))
    }

    @Test func actionsMapToTheNotificationActions() {
        #expect(WidgetAction(kind: .reminderDone(reminderId: "r")).proactiveAction == .reminderDone(id: "r"))
        #expect(WidgetAction(kind: .checkInProgress(goalId: "g")).proactiveAction
            == .checkIn(goalId: "g", answer: .yes))
    }

    @Test func enqueueIsDurableAndOrdered() throws {
        let inbox = Self.inbox()
        #expect(inbox.pending().isEmpty)
        let first = WidgetAction(kind: .reminderDone(reminderId: "r1"), createdAt: Date(timeIntervalSince1970: 100))
        let second = WidgetAction(kind: .checkInProgress(goalId: "g1"), createdAt: Date(timeIntervalSince1970: 200))
        try inbox.enqueue(second)
        try inbox.enqueue(first)
        #expect(inbox.pending().map(\.action) == [first, second])
        // Un archivo ilegible no tranca la cola, pero tampoco se borra (antes del
        // primer desbloqueo un tap válido es ilegible por la protección de datos).
        let unreadable = inbox.directory.appendingPathComponent("0000000000000-x.json")
        try Data("basura".utf8).write(to: unreadable)
        try Data("no json".utf8).write(to: inbox.directory.appendingPathComponent("ignorado.txt"))
        #expect(inbox.pending().map(\.action) == [first, second])
        #expect(FileManager.default.fileExists(atPath: unreadable.path))
        #expect(inbox.pending().map(\.action) == [first, second])
        #expect(WidgetActionInbox.shared()?.directory.lastPathComponent == "Actions" || WidgetActionInbox.shared() == nil)
    }

    @Test func drainAppliesEachOnceAndKeepsOnlyTheFailedOnes() async throws {
        let inbox = Self.inbox()
        try inbox.enqueue(WidgetAction(kind: .reminderDone(reminderId: "ok"), createdAt: Date(timeIntervalSince1970: 1)))
        try inbox.enqueue(WidgetAction(kind: .reminderDone(reminderId: "gone"), createdAt: Date(timeIntervalSince1970: 2)))
        try inbox.enqueue(WidgetAction(kind: .reminderDone(reminderId: "busy"), createdAt: Date(timeIntervalSince1970: 3)))
        let seen = Locked<[String]>([])
        let applied = await inbox.drain { action in
            guard case .reminderDone(let id) = action.kind else { return .failed }
            seen.mutate { $0.append(id) }
            switch id {
            case "ok": return .applied
            case "gone": return .obsolete
            default: return .failed
            }
        }
        #expect(applied == 1)
        #expect(seen.value == ["ok", "gone", "busy"])
        #expect(inbox.pending().map(\.action.kind) == [.reminderDone(reminderId: "busy")])
        #expect(await inbox.drain { _ in .applied } == 1)
        #expect(inbox.pending().isEmpty)
        #expect(await inbox.drain { _ in .applied } == 0)
    }

    @Test func drainRunsTheSameProactiveHandlerAsNotifications() async throws {
        let queue = try AnimaDatabase.temporary()
        let reminders = AnimaReminderStore(queue: queue)
        let other = OtherModel(queue: queue)
        let notifications = FakeNotificationScheduler(status: .granted)
        let scheduler = ProactiveScheduler(scheduler: notifications, reminders: reminders, otherModel: other)
        let reminder = try await reminders.create(text: "Llamar al banco", fireAt: Date().addingTimeInterval(3600))
        let goalId = await other.ingestStated(statement: "Correr", desiredState: .progressCheckIn(everyDays: 1),
                                              evidence: "t")
        await scheduler.sync()
        #expect(notifications.scheduled.keys.contains(ProactiveNotificationIDs.reminderPrefix + reminder.id))

        let inbox = Self.inbox()
        try inbox.enqueue(WidgetAction(kind: .reminderDone(reminderId: reminder.id)))
        try inbox.enqueue(WidgetAction(kind: .checkInProgress(goalId: goalId)))
        let handler = ProactiveActionHandler(reminders: reminders, otherModel: other, scheduler: scheduler)
        let applied = await inbox.drain { await handler.handle($0) }

        #expect(applied == 2)
        #expect(await reminders.reminder(id: reminder.id)?.status == .done)
        // El handler re-sincronizó: la notificación del recordatorio hecho ya no está.
        #expect(!notifications.scheduled.keys.contains(ProactiveNotificationIDs.reminderPrefix + reminder.id))
        let checkIn = await other.lastCheckIn(goalId: goalId)
        #expect(checkIn?.answer == .yes)
        #expect(checkIn?.note == ProactiveActionHandler.widgetNote)
        #expect(await other.streak(goalId: goalId) == 1)
        // Reaplicar (tap doble) no rompe nada.
        try inbox.enqueue(WidgetAction(kind: .reminderDone(reminderId: reminder.id)))
        #expect(await inbox.drain { await handler.handle($0) } == 0)
        #expect(await reminders.reminder(id: reminder.id)?.status == .done)
    }

    // MARK: - Optimista

    @Test func optimisticDoneRemovesOrRollsTheReminder() {
        let cal = WidgetSnapshotTests.calendar
        let now = WidgetSnapshotTests.wednesday8am
        let snapshot = WidgetSnapshot(
            generatedAt: now, selfName: "A", plasticity: 1, nights: 0,
            reminders: [.init(id: "once", text: "Banco", fireAt: WidgetSnapshotTests.at(9)),
                        .init(id: "daily", text: "Agua", fireAt: WidgetSnapshotTests.at(10), cadence: .daily),
                        .init(id: "fired", text: "Pastilla", fireAt: WidgetSnapshotTests.at(7), cadence: .daily,
                              delivered: true)],
            goals: [])
        let once = snapshot.applying(WidgetAction(kind: .reminderDone(reminderId: "once"), createdAt: now), calendar: cal)
        #expect(once.reminders.map(\.id) == ["daily", "fired"])
        let daily = snapshot.applying(WidgetAction(kind: .reminderDone(reminderId: "daily"), createdAt: now), calendar: cal)
        #expect(daily.reminders.first { $0.id == "daily" }?.fireAt == WidgetSnapshotTests.at(10, day: 8))
        let fired = snapshot.applying(WidgetAction(kind: .reminderDone(reminderId: "fired"), createdAt: now), calendar: cal)
        #expect(fired.reminders.map(\.id) == ["once", "daily"])
        let unknown = snapshot.applying(WidgetAction(kind: .reminderDone(reminderId: "nope"), createdAt: now), calendar: cal)
        #expect(unknown == snapshot)
    }

    @Test func optimisticProgressGrowsTheStreakOncePerDay() {
        let cal = WidgetSnapshotTests.calendar
        let now = WidgetSnapshotTests.wednesday8am
        let snapshot = WidgetSnapshot(
            generatedAt: now, selfName: "A", plasticity: 1, nights: 0, reminders: [],
            goals: [.init(id: "g", statement: "Leer", checkIn: CheckInCadence(cadence: .daily, hour: 20, minute: 0),
                          streak: 3, lastProgressAt: WidgetSnapshotTests.at(21, day: 6)),
                    .init(id: "cold", statement: "Correr", streak: 5, lastProgressAt: WidgetSnapshotTests.at(9, day: 1))])
        let tap = WidgetAction(kind: .checkInProgress(goalId: "g"), createdAt: now)
        let once = snapshot.applying(tap, calendar: cal)
        #expect(once.goals[0].streak == 4)
        #expect(once.goals[0].lastAnsweredAt == now)
        #expect(once.day(at: now, calendar: cal).pendingCheckIn == nil)
        let twice = once.applying(WidgetAction(kind: .checkInProgress(goalId: "g"), createdAt: now.addingTimeInterval(60)),
                                  calendar: cal)
        #expect(twice.goals[0].streak == 4)
        // Racha vencida: vuelve a empezar en 1.
        let cold = snapshot.applying(WidgetAction(kind: .checkInProgress(goalId: "cold"), createdAt: now), calendar: cal)
        #expect(cold.goals[1].streak == 1)
        #expect(snapshot.applying(WidgetAction(kind: .checkInProgress(goalId: "nope"), createdAt: now), calendar: cal)
            == snapshot)
    }
}

extension WidgetActionInboxTests {
    /// Cada cambio de recordatorios/metas pasa por sync(): ahí se republica el widget.
    @Test func everySyncNotifiesTheWidgetHookEvenWhenDisabled() async throws {
        let queue = try AnimaDatabase.temporary()
        let reminders = AnimaReminderStore(queue: queue)
        let defaults = UserDefaults(suiteName: "widget-hook-\(UUID().uuidString)")!
        let preference = ProactivePreference(defaults: defaults)
        let scheduler = ProactiveScheduler(scheduler: FakeNotificationScheduler(status: .granted), reminders: reminders,
                                           preference: preference)
        let calls = Locked(0)
        await scheduler.setAfterSync { calls.mutate { $0 += 1 } }
        await scheduler.sync()
        preference.isEnabled = false
        await scheduler.sync()
        #expect(calls.value == 2)
        await scheduler.setAfterSync(nil)
        await scheduler.sync()
        #expect(calls.value == 2)
    }
}

extension WidgetActionInboxTests {
    /// Reaplicar un "Sí, avancé" (p. ej. murió la app entre aplicar y borrar el
    /// archivo) no duplica el check-in, y la respuesta lleva la hora del tap.
    @Test func reapplyingACheckInIsIdempotentAndKeepsTheTapTime() async throws {
        let queue = try AnimaDatabase.temporary()
        let other = OtherModel(queue: queue)
        let goalId = await other.ingestStated(statement: "Leer", desiredState: .progressCheckIn(everyDays: 1),
                                              evidence: "t")
        let handler = ProactiveActionHandler(reminders: nil, otherModel: other, scheduler: nil)
        let tapped = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        let tap = WidgetAction(kind: .checkInProgress(goalId: goalId), createdAt: tapped)

        #expect(await handler.handle(tap) == .applied)
        #expect(await handler.handle(tap) == .applied)
        #expect(await handler.handle(WidgetAction(kind: .checkInProgress(goalId: goalId),
                                                  createdAt: tapped.addingTimeInterval(60))) == .applied)

        let checkIns = await other.checkIns(goalId: goalId)
        #expect(checkIns.count == 1)
        #expect(checkIns.first?.answeredAt.map { abs($0.timeIntervalSince(tapped)) < 0.001 } == true)
        #expect(checkIns.first?.note == ProactiveActionHandler.widgetNote)
        #expect(await other.streak(goalId: goalId) == 1)
        // Un tap de otro día sí cuenta.
        let yesterday = WidgetAction(kind: .checkInProgress(goalId: goalId), createdAt: tapped.addingTimeInterval(-86_400))
        #expect(await handler.handle(yesterday) == .applied)
        #expect(await other.checkIns(goalId: goalId).count == 2)
        // Meta borrada: no aplica.
        #expect(await handler.handle(WidgetAction(kind: .checkInProgress(goalId: "nope"))) == .obsolete)
        #expect(await ProactiveActionHandler(reminders: nil, otherModel: nil, scheduler: nil)
            .handle(tap) == .failed)
    }

    @Test func checkInsFromTheChatStillAddRowsTheSameDay() async throws {
        let queue = try AnimaDatabase.temporary()
        let other = OtherModel(queue: queue)
        let goalId = await other.ingestStated(statement: "Leer", desiredState: .progressCheckIn(everyDays: 1),
                                              evidence: "t")
        _ = await other.recordCheckIn(goalId: goalId, answer: .yes, note: "widget", oncePerDay: true)
        _ = await other.recordCheckIn(goalId: goalId, answer: .yes, note: "leí 30 páginas")
        #expect(await other.checkIns(goalId: goalId).count == 2)
    }
}

extension WidgetActionInboxTests {
    /// La base falla de verdad (otra conexión con lock EXCLUSIVE: SQLITE_BUSY,
    /// lo mismo que ve un tap aplicado con la base ocupada): el tap NO se pierde,
    /// el recordatorio sigue abierto y el próximo drenaje lo aplica.
    @Test func aDatabaseFailureKeepsTheTapForTheNextDrain() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("busy-\(UUID().uuidString).sqlite")
        let queue = try AnimaDatabase.makeQueue(path: url.path)
        let reminders = AnimaReminderStore(queue: queue)
        let other = OtherModel(queue: queue)
        let reminder = try await reminders.create(text: "Pagar la luz", fireAt: Date().addingTimeInterval(3600))
        let goalId = await other.ingestStated(statement: "Leer", desiredState: .progressCheckIn(everyDays: 1),
                                              evidence: "t")
        let inbox = Self.inbox()
        try inbox.enqueue(WidgetAction(kind: .reminderDone(reminderId: reminder.id)))
        try inbox.enqueue(WidgetAction(kind: .checkInProgress(goalId: goalId)))
        let handler = ProactiveActionHandler(reminders: reminders, otherModel: other, scheduler: nil)

        let locker = try DatabaseQueue(path: url.path)
        let release = DispatchSemaphore(value: 0)
        let holding = Task.detached {
            try? locker.inTransaction(.exclusive) { _ in
                release.wait()
                return .commit
            }
        }
        while await reminders.reminder(id: reminder.id) != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await inbox.drain { await handler.handle($0) } == 0)
        #expect(inbox.pending().count == 2)
        release.signal()
        await holding.value
        try locker.close()

        #expect(await reminders.reminder(id: reminder.id)?.status == .scheduled)
        #expect(await other.checkIns(goalId: goalId).isEmpty)
        #expect(await inbox.drain { await handler.handle($0) } == 2)
        #expect(inbox.pending().isEmpty)
        #expect(await reminders.reminder(id: reminder.id)?.status == .done)
        #expect(await other.checkIns(goalId: goalId).count == 1)
        try queue.close()
    }

    /// "Hecho" reaplicado: obsoleto la segunda vez; en uno que se repite, done_at
    /// queda en la hora del tap y nunca retrocede.
    @Test func reminderDoneFromTheWidgetIsIdempotent() async throws {
        let queue = try AnimaDatabase.temporary()
        let reminders = AnimaReminderStore(queue: queue)
        let handler = ProactiveActionHandler(reminders: reminders, otherModel: nil, scheduler: nil)
        let once = try await reminders.create(text: "Banco", fireAt: Date().addingTimeInterval(3600))
        let tap = WidgetAction(kind: .reminderDone(reminderId: once.id), createdAt: Date().addingTimeInterval(-120))
        #expect(await handler.handle(tap) == .applied)
        #expect(await handler.handle(tap) == .obsolete)
        let done = await reminders.reminder(id: once.id)
        #expect(done?.status == .done)
        #expect(done?.doneAt.map { abs($0.timeIntervalSince(tap.createdAt)) < 0.001 } == true)
        #expect(await handler.handle(WidgetAction(kind: .reminderDone(reminderId: "nope"))) == .obsolete)

        let daily = try await reminders.create(text: "Agua", fireAt: Date().addingTimeInterval(3600), repeat: .daily)
        let later = WidgetAction(kind: .reminderDone(reminderId: daily.id), createdAt: Date().addingTimeInterval(-60))
        let earlier = WidgetAction(kind: .reminderDone(reminderId: daily.id), createdAt: Date().addingTimeInterval(-600))
        #expect(await handler.handle(later) == .applied)
        #expect(await handler.handle(earlier) == .applied)
        let rolled = await reminders.reminder(id: daily.id)
        #expect(rolled?.status == .scheduled)
        #expect(rolled?.doneAt.map { abs($0.timeIntervalSince(later.createdAt)) < 0.001 } == true)
    }
}
