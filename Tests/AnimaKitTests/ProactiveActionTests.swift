import Foundation
import Testing
@testable import AnimaKit

@Suite struct ProactiveActionTests {
    typealias F = ProactiveFixtures

    @Test func mapsActionIdentifiersAndDeepLinks() {
        let reminder = AnimaDeepLink.reminder(id: "r1").url
        let goal = AnimaDeepLink.goal(id: "g1").url
        typealias IDs = ProactiveNotificationIDs
        #expect(ProactiveNotificationAction.from(actionIdentifier: IDs.reminderDoneAction, link: reminder)
                == .reminderDone(id: "r1"))
        #expect(ProactiveNotificationAction.from(actionIdentifier: IDs.reminderSnoozeAction, link: reminder)
                == .reminderSnooze(id: "r1"))
        #expect(ProactiveNotificationAction.from(actionIdentifier: IDs.checkInYesAction, link: goal)
                == .checkIn(goalId: "g1", answer: .yes))
        #expect(ProactiveNotificationAction.from(actionIdentifier: IDs.checkInNoAction, link: goal)
                == .checkIn(goalId: "g1", answer: .no))
        let tap = "com.apple.UNNotificationDefaultActionIdentifier"
        #expect(ProactiveNotificationAction.from(actionIdentifier: tap, link: goal) == .open(.goal(id: "g1")))
        #expect(ProactiveNotificationAction.from(actionIdentifier: IDs.checkInYesAction, link: reminder)
                == .open(.reminder(id: "r1")))
        #expect(ProactiveNotificationAction.from(actionIdentifier: tap, link: nil) == nil)
        #expect(ProactiveNotificationAction.from(actionIdentifier: tap, link: URL(string: "https://x.y")!) == nil)
    }

    @Test func actionsRunWithoutOpeningTheApp() async throws {
        let w = try F.world(status: .granted)
        let r = try await w.reminders.create(text: "pagar", fireAt: F.date(2026, 10, 5, 15))
        let snoozable = try await w.reminders.create(text: "llamar", fireAt: F.date(2026, 10, 5, 16))
        let goal = await w.other.ingestStated(statement: "invertir", desiredState: .progressCheckIn(everyDays: 2),
                                              evidence: "")
        await w.other.setCheckIn(id: goal, CheckInCadence(cadence: .daily))
        let handler = ProactiveActionHandler(reminders: w.reminders, otherModel: w.other, scheduler: w.scheduler)

        #expect(await handler.handle(.reminderDone(id: r.id)))
        #expect(await w.reminders.reminder(id: r.id)?.status == .done)
        #expect(await handler.handle(.reminderSnooze(id: snoozable.id)))
        #expect(await w.reminders.reminder(id: snoozable.id)?.fireAt == F.start.addingTimeInterval(3600))
        #expect(await handler.handle(.checkIn(goalId: goal, answer: .yes)))
        let last = try #require(await w.other.lastCheckIn(goalId: goal))
        #expect(last.answer == .yes && last.note == ProactiveActionHandler.notificationNote)
        // Contestó desde la notificación ⇒ al abrir, la pregunta no se repite en el chat.
        #expect(await w.reconciler.checkInPrompt(goalId: goal, sessionId: nil) == nil)
        #expect(Set(await w.fake.pendingIds()) == ["anima-checkin-\(goal)", "anima-reminder-\(snoozable.id)"])

        #expect(await handler.handle(.reminderDone(id: "nope")) == false)
        #expect(await handler.handle(.checkIn(goalId: "nope", answer: .no)) == false)
        #expect(await handler.handle(.open(.glasses)) == false)
        let bare = ProactiveActionHandler(reminders: nil, otherModel: nil, scheduler: nil)
        #expect(await bare.handle(.reminderSnooze(id: r.id)) == false)
    }

    @MainActor
    @Test func notificationsSettingsModelReflectsState() async throws {
        let w = try F.world(status: .notDetermined)
        _ = try await w.reminders.create(text: "x", fireAt: F.date(2026, 10, 6, 9))
        let model = NotificationsSettingsModel(scheduler: w.fake, reminders: w.reminders)
        await model.refresh()
        #expect(model.status == .notDetermined && model.scheduledCount == 1)
        #expect(model.hubSummary == "Sin decidir")
        await model.requestPermission()
        #expect(model.status == .granted)
        #expect(model.hubSummary == "Permitidas · 1 programadas")
        #expect(NotificationsSettingsModel.hubSummary(status: .denied, scheduled: 4) == "Denegadas")
        #expect(SettingsRoute.allCases.count == 6)
        #expect(SettingsRoute.allCases.last == .notifications)
        #expect(NotificationsSettingsModel.statusLabel(.granted) == "Permitidas")
        #expect(NotificationsSettingsModel.statusLabel(.denied) == "Denegadas")
        #expect(NotificationsSettingsModel.statusLabel(.notDetermined) == "Sin decidir")
        #expect(NotificationsSettingsModel.countLabel(1) == "1 recordatorio programado")
        #expect(NotificationsSettingsModel.countLabel(3) == "3 recordatorios programados")
    }

    /// Campo batch 5 #3: "Avisos de Anima" se prende y apaga desde la app.
    @MainActor
    @Test func avisosDeAnimaToggleCancelsAndResyncs() async throws {
        let suite = "anima.test.proactive.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = ProactivePreference(defaults: defaults)
        #expect(preference.isEnabled)
        let w = try F.world(status: .granted)
        let scheduler = ProactiveScheduler(scheduler: w.fake, reminders: w.reminders, otherModel: w.other,
                                           selfName: { "Lumen" }, calendar: F.calendar, preference: preference)
        let r = try await w.reminders.create(text: "x", fireAt: F.date(2026, 10, 6, 9))
        await w.fake.schedule(LocalNotificationRequest(id: "handoff-x", title: "", body: "", trigger: .immediate,
                                                       categoryId: "", deepLink: nil))
        #expect(await scheduler.sync() == ["anima-reminder-\(r.id)"])

        let model = NotificationsSettingsModel(scheduler: w.fake, reminders: w.reminders, preference: preference)
        model.onEnabledChanged = { _ = await scheduler.sync() }
        await model.refresh()
        #expect(model.enabled && model.hubSummary == "Permitidas · 1 programadas")

        await model.setEnabled(false)
        #expect(!preference.isEnabled && !model.enabled)
        #expect(await w.fake.pendingIds() == ["handoff-x"])            // lo de Anima, cancelado; lo ajeno, no
        #expect(await w.reminders.scheduledCount() == 1)               // el store queda intacto
        #expect(model.hubSummary == "Avisos apagados")
        let intention = Intention(id: "i9", goalId: "g", observablesJSON: "{}", gap: "", proposedText: "x",
                                  outcome: .pending, createdAt: F.start)
        await scheduler.notify(intention)
        #expect(w.fake.scheduled["anima-intention-i9"] == nil)

        await model.setEnabled(true)
        #expect(await w.fake.pendingIds() == ["anima-reminder-\(r.id)", "handoff-x"])
        #expect(NotificationsSettingsModel.detail(status: .granted, enabled: true) == "Permiso del iPhone: permitido.")
        #expect(NotificationsSettingsModel.detail(status: .granted, enabled: false).hasPrefix("Apagados"))
        #expect(NotificationsSettingsModel.detail(status: .denied, enabled: true).contains("denegado"))
        #expect(NotificationsSettingsModel.detail(status: .notDetermined, enabled: true).contains("permiso"))
    }
}
