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
        let card = XCTAttachment(screenshot: app.screenshot())
        card.name = "metas-control-de-hora"
        card.lifetime = .keepAlways
        add(card)

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

/// Campo 2026-10-15 ("ya no quiero ahorrar…" y quedaban las dos): dejar una meta
/// en Metas cancela su seguimiento (sale de Recordatorios) y desde el Historial
/// se reactiva con su seguimiento.
final class GoalsLeaveUITests: AnimaUITestCase {
    @MainActor
    private func byPrefix(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor
    func testLeavingAGoalCancelsItsFollowUpAndReactivatingRestoresIt() {
        let app = makeApp(reset: true)
        app.launchArguments.append(GoalsUITests.seedFlag)
        app.launch()
        onboard(app)
        openTab(app, "Metas")
        let cadence = byPrefix(app, "goal.checkin.cadence.")
        tap(cadence, until: app.buttons["Diario"])
        tap(app.buttons["Diario"])
        waitUntil(byPrefix(app, "goal.checkin.status."), "label BEGINSWITH 'Seguimiento cada día'")

        // El seguimiento aparece en Recordatorios.
        openTab(app, "Recordatorios")
        let followUp = element(app, "reminders.checkin")
        waitFor(followUp)

        // Eliminar (dejar) la meta.
        openTab(app, "Metas")
        let statement = text(app, "Ahorrar 10 millones para invertir")
        waitFor(statement)
        statement.swipeLeft()
        tap(app.buttons["Eliminar"])
        let confirm = app.sheets.buttons["Eliminar"].exists ? app.sheets.buttons["Eliminar"]
            : app.buttons.matching(NSPredicate(format: "label == 'Eliminar'")).element(boundBy: 0)
        tap(confirm)
        let history = element(app, "goals.history")
        waitFor(history)

        // Su seguimiento ya no está en Recordatorios.
        openTab(app, "Recordatorios")
        waitUntil(element(app, "reminders.checkin"), "exists == false")
        screenshot(app, "recordatorios-sin-seguimiento")

        // Historial → Reactivar: vuelve a las metas activas CON su seguimiento
        // (review #45: reversible de verdad), y vuelve a Recordatorios.
        openTab(app, "Metas")
        let row = text(app, "abandonada")
        tap(element(app, "goals.history"), until: row)
        row.swipeLeft()
        tap(app.buttons["Reactivar"])
        waitUntil(byPrefix(app, "goal.checkin.status."), "label BEGINSWITH 'Seguimiento cada día a las 8:00 p. m.'")
        waitUntil(element(app, "goals.history"), "exists == false")
        screenshot(app, "metas-reactivada")
        openTab(app, "Recordatorios")
        waitFor(element(app, "reminders.checkin"))
    }
}
