// RemindersUITests.swift — la tab Recordatorios (campo batch 5 #6): un
// recordatorio sembrado aparece con lo que ella dirá y cuándo; deslizar →
// "Cancelar" lo quita y el contador de Ajustes → Notificaciones baja; "N
// programados" lleva a la tab. Y las aprobaciones, que cedieron su tab: aviso
// sobre el chat → Ajustes → Mente → "Por aprobar".

import XCTest

final class RemindersUITests: AnimaUITestCase {
    @MainActor
    private func notificationsCount(_ app: XCUIApplication) -> XCUIElement {
        openSettings(app, "notifications")
        return element(app, "settings.notifications.count")
    }

    @MainActor
    func testSeededReminderShowsInItsTabAndCancelLowersTheCount() {
        let app = makeApp(reset: true)
        app.launchArguments.append("--uitest-seed-reminder=3600")
        app.launch()
        onboard(app)
        XCTAssertFalse(app.tabBars.buttons["Aprobaciones"].exists)

        waitUntil(notificationsCount(app), "label == '1 recordatorio programado'")
        // Batch 8 #7: "Avisarme cuando despierte" vive aquí (sin permiso del iPhone: deshabilitado).
        let wake = element(app, "settings.notifications.wake")
        waitFor(wake)
        XCTAssertFalse(wake.isEnabled)
        // "N programados" → la tab Recordatorios.
        tap(element(app, "settings.notifications.list"))
        waitUntil(app.tabBars.buttons["Recordatorios"], "isSelected == true")

        let item = element(app, "reminders.item")
        waitFor(item)
        XCTAssertTrue(item.label.contains("Cita médica de prueba"), item.label)
        XCTAssertTrue(item.label.contains("Oye, ya casi es tu cita médica de prueba."), item.label)
        item.swipeLeft()
        tap(app.buttons["Cancelar"])
        waitFor(element(app, "reminders.empty"))
        XCTAssertFalse(element(app, "reminders.item").exists)

        openTab(app, "Ajustes")
        waitUntil(element(app, "settings.notifications.count"), "label == '0 recordatorios programados'")
    }

    @MainActor
    func testPendingApprovalBannerLeadsToMind() {
        let app = makeApp(reset: true)
        app.launchArguments.append("--uitest-seed-inferred-goal")
        app.launch()
        onboard(app)

        let banner = element(app, "chat.approvalsBanner")
        waitUntil(banner, "label CONTAINS 'Tienes 1 cambio por aprobar'")
        tap(banner)
        waitUntil(app.tabBars.buttons["Ajustes"], "isSelected == true")
        waitFor(element(app, "approvals.section"))
        waitFor(text(app, "Dormir 7 horas"))
        tap(app.buttons["Confirmar"])
        waitFor(element(app, "approvals.empty"))

        openTab(app, "Chat")
        waitUntil(element(app, "chat.approvalsBanner"), "exists == false")
    }
}
