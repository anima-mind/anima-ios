// GoalsUITests.swift — check-in por meta desde la vista Metas: una meta sembrada
// (`--uitest-seed-goal`) → cadencia Diario → persiste al volver a la vista y al
// relanzar la app. Waits por identifier (el id de la meta es un UUID).

import XCTest

final class GoalsUITests: AnimaUITestCase {
    static let seedFlag = "--uitest-seed-goal"

    @MainActor
    private func launchSeeded(reset: Bool) -> XCUIApplication {
        let app = makeApp(reset: reset)
        app.launchArguments.append(Self.seedFlag)
        app.launch()
        return app
    }

    @MainActor
    private func byPrefix(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor
    func testDailyCheckInPersistsAcrossViewAndRelaunch() {
        let app = launchSeeded(reset: true)
        onboard(app)
        openTab(app, "Metas")

        let status = byPrefix(app, "goal.checkin.status.")
        waitUntil(status, "label BEGINSWITH 'Sin check-in'")
        let cadence = byPrefix(app, "goal.checkin.cadence.")
        tap(cadence, until: app.buttons["Diario"])
        tap(app.buttons["Diario"])
        waitUntil(status, "label BEGINSWITH 'Check-in cada día a las 20:00'")
        waitFor(byPrefix(app, "goal.checkin.time."))

        // Reabrir la vista: se relee de la base.
        openTab(app, "Chat")
        openTab(app, "Metas")
        waitUntil(byPrefix(app, "goal.checkin.status."), "label BEGINSWITH 'Check-in cada día a las 20:00'")

        // Relanzar sin reset: la cadencia vive en SQLite, no en memoria.
        app.terminate()
        let relaunched = launchSeeded(reset: false)
        waitForChat(relaunched)
        openTab(relaunched, "Metas")
        waitUntil(byPrefix(relaunched, "goal.checkin.status."), "label BEGINSWITH 'Check-in cada día a las 20:00'")
    }
}
