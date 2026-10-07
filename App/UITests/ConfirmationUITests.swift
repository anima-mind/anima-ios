// ConfirmationUITests.swift — el sheet de confirmación rediseñado (batch 5b
// #1/#6/#8): a la medida del contenido, Autorizar / Autorizar siempre /
// Cancelar; "Autorizar siempre" deja de preguntar la misma acción.

import XCTest

final class ConfirmationUITests: AnimaUITestCase {
    /// El TCC real de EventKit (la tool corre de verdad): se niega para seguir.
    @MainActor
    private func denyCalendarIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: scaled(6)) else { return }
        for label in ["Don’t Allow", "Don't Allow", "No permitir"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            return
        }
    }

    @MainActor
    func testAlwaysAllowStopsAskingForTheSameAction() {
        let app = launch()
        onboard(app, provider: .anthropic(key: "sk-ant-api03-test"))

        send(app, "agéndame reunión con Pedro")
        let sheet = element(app, "confirm.sheet")
        waitFor(sheet, timeout: 20)
        XCTAssertTrue(text(app, "Confirmar acción").exists || text(app, "CONFIRMAR ACCIÓN").exists)
        XCTAssertTrue(text(app, "Calendario del iPhone · crear").exists)
        // A la medida: el sheet no ocupa media pantalla vacía.
        XCTAssertLessThan(sheet.frame.height, app.frame.height * 0.5)
        // Batch 8 #4: X en la fila del título (= Cancelar, fail-closed).
        assertSheetClose(app, "confirm")
        screenshot(app, "batch8-04-confirm")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "confirmation-sheet"
        shot.lifetime = .keepAlways
        add(shot)
        tap(app.buttons["confirm.always"])
        waitUntil(sheet, "exists == false")
        denyCalendarIfAsked()
        waitFor(assistantMessage(app, value: "done", labelContains: "Calendario"), timeout: 20)

        send(app, "agéndame otra con Pedro")
        let second = app.descendants(matching: .any).matching(identifier: "chat.assistantMessage")
            .matching(NSPredicate(format: "value == 'done' AND label CONTAINS 'Calendario'"))
        XCTAssertTrue(NSPredicate(format: "count >= 2").evaluate(with: second) || {
            let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count >= 2"), object: second)
            return XCTWaiter().wait(for: [exp], timeout: self.scaled(20)) == .completed
        }())
        XCTAssertFalse(element(app, "confirm.sheet").exists, "la acción autorizada siempre ya no pregunta")

        // Revocable en Ajustes → Skills → Permisos.
        openSettings(app, "skills")
        let revoke = app.buttons["permissions.revoke"]
        scrollTo(revoke, in: app)
        tap(revoke)
        waitFor(element(app, "permissions.empty"))
    }
}
