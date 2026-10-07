import Foundation
import Testing
import GRDB
@testable import AnimaKit

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
        // Un archivo ilegible no tranca la cola: se descarta.
        try Data("basura".utf8).write(to: inbox.directory.appendingPathComponent("0000000000000-x.json"))
        try Data("no json".utf8).write(to: inbox.directory.appendingPathComponent("ignorado.txt"))
        #expect(inbox.pending().map(\.action) == [first, second])
        #expect(WidgetActionInbox.shared()?.directory.lastPathComponent == "Actions" || WidgetActionInbox.shared() == nil)
    }

    @Test func drainAppliesEachOnceAndEmptiesTheQueue() async throws {
        let inbox = Self.inbox()
        try inbox.enqueue(WidgetAction(kind: .reminderDone(reminderId: "ok")))
        try inbox.enqueue(WidgetAction(kind: .reminderDone(reminderId: "gone")))
        let seen = Locked<[String]>([])
        let applied = await inbox.drain { action in
            guard case .reminderDone(let id) = action.kind else { return false }
            seen.mutate { $0.append(id) }
            return id == "ok"
        }
        #expect(applied == 1)
        #expect(Set(seen.value) == ["ok", "gone"])
        #expect(inbox.pending().isEmpty)
        #expect(await inbox.drain { _ in true } == 0)
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
        let applied = await inbox.drain { await handler.handle($0.proactiveAction, note: ProactiveActionHandler.widgetNote) }

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
        #expect(await inbox.drain { await handler.handle($0.proactiveAction, note: ProactiveActionHandler.widgetNote) } == 0)
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
