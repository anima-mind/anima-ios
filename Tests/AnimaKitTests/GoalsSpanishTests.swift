import Foundation
import Testing
@testable import AnimaKit

// Batch 5b #9: "español e inglés combinado, no hay forma de eliminar una meta".

@MainActor
@Suite struct GoalsSpanishTests {
    typealias F = ProactiveFixtures

    @Test func labelsAndFollowUpInSpanish() {
        #expect(GoalsViewModel.sourceLabel(.stated) == "Declarada")
        #expect(GoalsViewModel.sourceLabel(.inferred) == "Inferida")
        #expect(GoalsViewModel.sourceLabel(.structural) == "Estructural")
        let dates = AnimaDateText(calendar: F.calendar)
        #expect(GoalsViewModel.followUpPhrase(CheckInCadence(cadence: .weekly, hour: 20, weekday: 1), dates: dates)
                == "cada domingo a las 8:00 p. m.")
        #expect(GoalsViewModel.followUpPhrase(CheckInCadence(cadence: .weekdays, hour: 7, minute: 30), dates: dates)
                == "entre semana a las 7:30 a. m.")
        #expect(GoalsViewModel.followUpPhrase(CheckInCadence(cadence: .daily, hour: 20), dates: dates)
                == "cada día a las 8:00 p. m.")
        #expect(GoalsViewModel.followUpPhrase(.off, dates: dates) == "sin seguimiento")
    }

    @Test func deleteAbandonsCancelsAvisosAndGoesToHistory() async throws {
        let w = try F.world(status: .granted)
        let model = GoalsViewModel(otherModel: w.other)
        let scheduler = w.scheduler
        model.onCheckInChanged = { _ = await scheduler.sync() }
        let a = await w.other.ingestStated(statement: "correr", desiredState: .progressCheckIn(everyDays: 2), evidence: "")
        let b = await w.other.ingestStated(statement: "leer", desiredState: .progressCheckIn(everyDays: 2), evidence: "")
        await w.other.setCheckIn(id: a, CheckInCadence(cadence: .daily))
        _ = await w.scheduler.sync()
        await model.refresh()
        #expect(model.currentGoals.count == 2 && model.pastGoals.isEmpty)
        #expect(GoalsViewModel.checkInStatus(try #require(model.goals.first { $0.id == a }), nil)
                    .hasPrefix("Seguimiento cada día a las"))
        #expect(GoalsViewModel.checkInStatus(try #require(model.goals.first { $0.id == b }), nil) == "Sin seguimiento")

        await model.delete(try #require(model.goals.first { $0.id == a }))
        #expect(model.pastGoals.map(\.id) == [a])
        #expect(await w.fake.pendingIds().isEmpty)                 // sus avisos, cancelados
        await model.markAchieved(try #require(model.goals.first { $0.id == b }))
        #expect(model.currentGoals.isEmpty && model.pastGoals.count == 2)
    }
}
