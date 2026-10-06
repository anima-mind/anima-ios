import Foundation
import Testing
@testable import AnimaKit

// Campo batch 5 #6: "sale '1 recordatorio programado' pero no sé cuál". La
// lista de lo programado: qué, qué te dirá, cuándo y si se repite; Hecho y
// Cancelar pasan por el store y re-sincronizan las notificaciones.

@MainActor
@Suite struct RemindersListTests {
    typealias F = ProactiveFixtures

    private func model(_ w: F.World, syncs: Locked<Int> = Locked(0)) -> RemindersViewModel {
        let model = RemindersViewModel(store: w.reminders, otherModel: w.other)
        model.now = { w.clock.value }
        model.dates = AnimaDateText(calendar: F.calendar)
        let scheduler = w.scheduler
        model.onChange = {
            syncs.mutate { $0 += 1 }
            await scheduler.sync()
        }
        return model
    }

    @Test func listsRemindersAndActiveCheckIns() async throws {
        let w = try F.world(status: .granted)
        let list = model(w)
        await list.refresh()
        #expect(list.isEmpty)

        _ = try await w.reminders.create(text: "cita médica", message: "Oye, en media hora tienes la cita",
                                         fireAt: F.date(2026, 10, 5, 20, 30))
        _ = try await w.reminders.create(text: "vitaminas", fireAt: F.date(2026, 10, 6, 9), repeat: .daily)
        _ = try await w.reminders.create(text: "pagar el arriendo", fireAt: F.date(2026, 10, 12, 9))
        let goalId = await w.other.ingestStated(statement: "correr", desiredState: .progressCheckIn(everyDays: 2),
                                                evidence: "")
        _ = await w.other.ingestStated(statement: "leer", desiredState: .progressCheckIn(everyDays: 2), evidence: "")
        await w.other.setCheckIn(id: goalId, CheckInCadence(cadence: .daily, hour: 20))
        await list.refresh()

        #expect(list.reminders.map(\.title) == ["Cita médica", "Vitaminas", "Pagar el arriendo"])
        #expect(list.reminders.map(\.schedule) == ["hoy 8:30 p. m.", "mañana 9:00 a. m. · cada día",
                                                   "lun 12 oct, 9:00 a. m."])
        #expect(list.reminders.map(\.spoken) == ["Oye, en media hora tienes la cita", nil, nil])
        #expect(list.checkIns == [RemindersViewModel.Item(id: "checkin-\(goalId)", kind: .checkIn(goalId: goalId),
                                                          title: "Check-in · correr", spoken: nil,
                                                          schedule: "cada día a las 20:00")])
        #expect(!list.isEmpty)
    }

    @Test func doneAndCancelGoThroughTheStoreAndResync() async throws {
        let w = try F.world(status: .granted)
        let syncs = Locked(0)
        let list = model(w, syncs: syncs)
        let a = try await w.reminders.create(text: "a", fireAt: F.date(2026, 10, 6, 9))
        let b = try await w.reminders.create(text: "b", fireAt: F.date(2026, 10, 7, 9))
        _ = await w.scheduler.sync()
        await list.refresh()
        #expect(w.fake.scheduled.count == 2)

        let first = try #require(list.reminders.first)
        await list.cancel(first)
        #expect(await w.reminders.reminder(id: a.id)?.status == .cancelled)
        #expect(list.reminders.map(\.id) == [b.id])
        #expect(Array(w.fake.scheduled.keys) == ["anima-reminder-\(b.id)"])

        await list.complete(try #require(list.reminders.first))
        #expect(await w.reminders.reminder(id: b.id)?.status == .done)
        #expect(list.reminders.isEmpty && w.fake.scheduled.isEmpty)
        #expect(syncs.value == 2)

        let checkIn = RemindersViewModel.Item(id: "checkin-g", kind: .checkIn(goalId: "g"), title: "", spoken: nil,
                                              schedule: "")
        await list.cancel(checkIn)
        await list.complete(checkIn)
        #expect(syncs.value == 2)   // un check-in no se cancela desde aquí
        #expect(RemindersViewModel.capitalized("") == "")
    }

    @Test func checkInLeadsToItsGoal() async throws {
        let w = try F.world()
        let goals = GoalsViewModel(otherModel: w.other)
        let list = model(w)
        list.onOpenGoal = { goals.focus(goalId: $0) }
        list.onOpenGoal?("g1")
        #expect(goals.focusedGoalId == "g1")
        #expect(RemindersView.emptyHint.hasPrefix("Dime: «recuérdame mañana a las 9…»"))
    }

    @Test func approvalsBannerCopy() {
        #expect(ApprovalsInboxViewModel.bannerText(1) == "Tienes 1 cambio por aprobar")
        #expect(ApprovalsInboxViewModel.bannerText(3) == "Tienes 3 cambios por aprobar")
    }
}
