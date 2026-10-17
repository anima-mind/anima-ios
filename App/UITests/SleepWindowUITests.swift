// SleepWindowUITests.swift — Ajustes → Mente → "Hora de dormir": la fila con
// sus dos selectores (01:00–06:00 por defecto), cambiar el inicio y que quede
// persistido al relanzar; un rango de más de 12 h se rechaza.

import XCTest

final class SleepWindowUITests: AnimaUITestCase {
    static let locale = ["-AppleLanguages", "(es-CO)", "-AppleLocale", "es_CO"]

    @MainActor
    private func launchInSpanish(reset: Bool) -> XCUIApplication {
        let app = makeApp(reset: reset)
        app.launchArguments += Self.locale
        app.launch()
        return app
    }

    @MainActor
    func testSleepWindowChangesAndPersists() {
        let app = launchInSpanish(reset: true)
        onboard(app)
        openSettings(app, "mind")

        waitFor(element(app, "settings.sleepWindow"))
        let start = app.datePickers["settings.sleepWindow.start"]
        let end = app.datePickers["settings.sleepWindow.end"]
        waitFor(start)
        waitFor(end)
        XCTAssertEqual(pickerValue(start), "1:00 a.m.")
        XCTAssertEqual(pickerValue(end), "6:00 a.m.")

        tap(start)
        let hour = app.pickerWheels.element(boundBy: 0)
        waitFor(hour)
        hour.adjust(toPickerWheelValue: "2")
        dismissPopover(app)
        waitUntil(start, "exists == true")
        XCTAssertEqual(pickerValue(start), "2:00 a.m.")
        XCTAssertFalse(element(app, "settings.sleepWindow.notice").exists)
        screenshot(app, "hora-de-dormir")

        tap(end)
        let endPeriod = app.pickerWheels.element(boundBy: 2)
        waitFor(endPeriod)
        endPeriod.adjust(toPickerWheelValue: "p.m.")
        let notice = element(app, "settings.sleepWindow.notice")
        waitFor(notice)
        XCTAssertEqual(notice.label, "El rango debe durar entre 1 y 12 horas.")
        dismissPopover(app)
        XCTAssertEqual(pickerValue(app.datePickers["settings.sleepWindow.end"]), "6:00 a.m.")

        app.terminate()
        let relaunched = launchInSpanish(reset: false)
        waitForChat(relaunched)
        openSettings(relaunched, "mind")
        let persisted = relaunched.datePickers["settings.sleepWindow.start"]
        waitFor(persisted)
        XCTAssertEqual(pickerValue(persisted), "2:00 a.m.")
        XCTAssertEqual(pickerValue(relaunched.datePickers["settings.sleepWindow.end"]), "6:00 a.m.")
    }

    @MainActor
    private func dismissPopover(_ app: XCUIApplication) {
        let region = app.buttons["PopoverDismissRegion"]
        if region.waitForExistence(timeout: scaled(2)) { region.tap() }
        waitUntil(app.pickerWheels.firstMatch, "exists == false")
    }

    @MainActor
    private func pickerValue(_ picker: XCUIElement) -> String? {
        let inner = picker.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS ':'")).firstMatch
        let value = (inner.exists ? inner.value : picker.value) as? String
        return value?.replacingOccurrences(of: "\u{202F}", with: " ")
    }
}
