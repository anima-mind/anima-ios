// RemindersUITests.swift — la lista de lo programado (campo batch 5 #6): un
// recordatorio sembrado aparece arriba en Metas con lo que ella dirá y cuándo;
// "Cancelar" lo quita y el contador de Ajustes → Notificaciones baja.

import XCTest

final class RemindersUITests: AnimaUITestCase {
    @MainActor
    private func notificationsCount(_ app: XCUIApplication) -> XCUIElement {
        openSettings(app, "notifications")
        return element(app, "settings.notifications.count")
    }

    @MainActor
    func testSeededReminderShowsInGoalsAndCancelLowersTheCount() {
        let app = makeApp(reset: true)
        app.launchArguments.append("--uitest-seed-reminder=3600")
        app.launch()
        onboard(app)

        waitUntil(notificationsCount(app), "label == '1 recordatorio programado'")

        openTab(app, "Metas")
        let item = element(app, "reminders.item")
        waitFor(item)
        XCTAssertTrue(item.staticTexts["Cita médica de prueba"].exists)
        XCTAssertTrue(item.staticTexts["«Oye, ya casi es tu cita médica de prueba.»"].exists)
        let actions = element(app, "reminders.actions")
        tap(actions, until: app.buttons["Cancelar"])
        tap(app.buttons["Cancelar"])
        waitFor(element(app, "reminders.empty"))
        XCTAssertFalse(element(app, "reminders.item").exists)

        openTab(app, "Ajustes")
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { tap(back) }
        waitUntil(notificationsCount(app), "label == '0 recordatorios programados'")

        // "N programados" lleva a la misma lista.
        tap(element(app, "settings.notifications.list"), until: element(app, "reminders.empty"))
    }
}
