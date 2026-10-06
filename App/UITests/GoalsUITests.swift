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
        waitUntil(status, "label BEGINSWITH 'Sin seguimiento'")
        let cadence = byPrefix(app, "goal.checkin.cadence.")
        tap(cadence, until: app.buttons["Diario"])
        tap(app.buttons["Diario"])
        waitUntil(status, "label BEGINSWITH 'Seguimiento cada día a las 8:00 p. m.'")
        // El control de hora y el resumen dicen la hora igual ("p. m.", no "p.m.").
        waitUntil(byPrefix(app, "goal.checkin.time."), "label ENDSWITH '8:00 p. m.'")

        // Reabrir la vista: se relee de la base.
        openTab(app, "Chat")
        openTab(app, "Metas")
        waitUntil(byPrefix(app, "goal.checkin.status."), "label BEGINSWITH 'Seguimiento cada día a las 8:00 p. m.'")

        // Relanzar sin reset: la cadencia vive en SQLite, no en memoria.
        app.terminate()
        let relaunched = launchSeeded(reset: false)
        waitForChat(relaunched)
        openTab(relaunched, "Metas")
        waitUntil(byPrefix(relaunched, "goal.checkin.status."), "label BEGINSWITH 'Seguimiento cada día a las 8:00 p. m.'")
    }
}

/// Batch 5b #9: etiquetas en español y "Eliminar" con confirmación ligera → Historial.
final class GoalsDeleteUITests: AnimaUITestCase {
    @MainActor
    func testDeleteGoalMovesItToHistory() {
        let app = makeApp(reset: true)
        app.launchArguments.append(GoalsUITests.seedFlag)
        app.launch()
        onboard(app)
        openTab(app, "Metas")
        let statement = text(app, "Ahorrar 10 millones para invertir")
        waitFor(statement)
        XCTAssertTrue(app.staticTexts.matching(identifier: "goal.source").firstMatch.label.lowercased() == "declarada")
        statement.swipeLeft()
        tap(app.buttons["Eliminar"])
        let confirm = app.sheets.buttons["Eliminar"].exists ? app.sheets.buttons["Eliminar"]
            : app.buttons.matching(NSPredicate(format: "label == 'Eliminar'")).element(boundBy: 0)
        tap(confirm)
        let history = element(app, "goals.history")
        waitFor(history)
        tap(history, until: text(app, "abandonada"))
        XCTAssertTrue(statement.exists)
    }
}
