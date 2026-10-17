// SleepWindowUITests.swift — Ajustes → Mente → "Hora de dormir": 01:00–06:00
// por defecto; las ruedas editan un borrador y "Listo" guarda el rango completo.
// El orden natural (primero Desde) llega a 23:00–05:00 sin rechazos
// intermedios, un rango de más de 12 h se rechaza sin cerrar la rueda ni perder
// lo elegido, y lo guardado persiste al relanzar.

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
    func testSleepWindowDraftCommitsFullRangeAndPersists() {
        let app = launchInSpanish(reset: true)
        onboard(app)
        openSettings(app, "mind")

        waitFor(element(app, "settings.sleepWindow"))
        let start = element(app, "settings.sleepWindow.start")
        let end = element(app, "settings.sleepWindow.end")
        waitFor(start)
        XCTAssertEqual(value(start), "1:00 a.m.")
        XCTAssertEqual(value(end), "6:00 a.m.")

        tap(start)
        wheel(app, 0).adjust(toPickerWheelValue: "11")
        wheel(app, 2).adjust(toPickerWheelValue: "p.m.")
        XCTAssertFalse(element(app, "settings.sleepWindow.notice").exists, "las ruedas no validan")
        XCTAssertEqual(value(start), "11:00 p.m.")
        tap(end)
        wheel(app, 0).adjust(toPickerWheelValue: "5")
        XCTAssertEqual(value(start), "11:00 p.m.", "pasar a Hasta conserva el borrador")
        tap(app.buttons["settings.sleepWindow.done"])
        waitUntil(app.pickerWheels.firstMatch, "exists == false")
        XCTAssertEqual(value(start), "11:00 p.m.")
        XCTAssertEqual(value(end), "5:00 a.m.")
        XCTAssertFalse(element(app, "settings.sleepWindow.notice").exists)
        screenshot(app, "hora-de-dormir")

        tap(start)
        wheel(app, 0).adjust(toPickerWheelValue: "4")
        tap(app.buttons["settings.sleepWindow.done"])
        let notice = element(app, "settings.sleepWindow.notice")
        waitFor(notice)
        XCTAssertEqual(notice.label, "El rango debe durar entre 1 y 12 horas")
        XCTAssertTrue(app.pickerWheels.firstMatch.exists, "la rueda no se cierra sola")
        XCTAssertEqual(value(start), "4:00 p.m.", "no se pierde lo elegido")
        screenshot(app, "hora-de-dormir-rechazo")

        app.terminate()
        let relaunched = launchInSpanish(reset: false)
        waitForChat(relaunched)
        openSettings(relaunched, "mind")
        let persisted = element(relaunched, "settings.sleepWindow.start")
        waitFor(persisted)
        XCTAssertEqual(value(persisted), "11:00 p.m.", "queda el último rango válido")
        XCTAssertEqual(value(element(relaunched, "settings.sleepWindow.end")), "5:00 a.m.")
    }

    @MainActor
    private func wheel(_ app: XCUIApplication, _ index: Int) -> XCUIElement {
        let wheel = app.pickerWheels.element(boundBy: index)
        waitFor(wheel)
        return wheel
    }

    @MainActor
    private func value(_ element: XCUIElement) -> String? {
        (element.value as? String)?
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
