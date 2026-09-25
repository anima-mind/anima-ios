// PermissionsUITests.swift — TCC REAL (sin dobles para permisos). El provider
// guionado pide la tool `calendar` cuando el mensaje menciona "calendario";
// EventKit dispara el diálogo del sistema y el test lo concede o lo niega.
//
// El estado TCC se resetea desde el runner con
// `XCUIApplication.resetAuthorizationStatus(for:)` antes de cada test (equivale a
// `xcrun simctl privacy <UDID> reset calendar com.joshuamoreno1.anima`, que
// scripts/ui-test.sh además corre antes de xcodebuild).

import XCTest

final class PermissionsUITests: AnimaUITestCase {

    private static let allowLabels = ["Allow Full Access", "Permitir acceso total", "Allow", "Permitir", "OK"]
    private static let denyLabels = ["Don’t Allow", "Don't Allow", "No permitir"]

    /// 6a. Conceder → la tool corre y el agente reporta el calendario.
    @MainActor
    func testCalendarAccessGranted() {
        let app = makeApp()
        app.resetAuthorizationStatus(for: .calendar)
        app.launch()
        onboard(app)

        installMonitor(allow: true)
        send(app, "¿Qué tengo en el calendario?")
        answerSystemAlert(in: app, allow: true)

        let reply = assistantMessage(app, value: "done", labelContains: "Calendario concedido")
        waitFor(reply, timeout: 20)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// 6b. Negar → fail-closed: mensaje de sin permiso, sin crash.
    @MainActor
    func testCalendarAccessDeniedFailsClosed() {
        let app = makeApp()
        app.resetAuthorizationStatus(for: .calendar)
        app.launch()
        onboard(app)

        installMonitor(allow: false)
        send(app, "Revisa mi calendario")
        answerSystemAlert(in: app, allow: false)

        let reply = assistantMessage(app, value: "done", labelContains: "Calendario sin permiso")
        waitFor(reply, timeout: 20)
        XCTAssertTrue(reply.label.contains("no ha concedido acceso"), reply.label)
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: Diálogo del sistema

    /// Red de seguridad: si el diálogo bloquea una interacción con la app, el
    /// monitor lo resuelve. El camino principal es `answerSystemAlert` (explícito).
    @MainActor
    private func installMonitor(allow: Bool) {
        let labels = allow ? Self.allowLabels : Self.denyLabels
        addUIInterruptionMonitor(withDescription: "TCC calendario") { alert in
            for label in labels where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    /// El diálogo TCC lo presenta SpringBoard: se espera y se toca explícitamente.
    /// Un tap durante la animación de entrada se pierde, así que se reintenta
    /// (acotado) hasta que el diálogo desaparezca.
    @MainActor
    private func answerSystemAlert(in app: XCUIApplication, allow: Bool) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: timeout), "No apareció el diálogo TCC")
        let labels = allow ? Self.allowLabels : Self.denyLabels
        for _ in 0..<3 {
            guard alert.exists else { return }
            guard let button = labels.lazy.map({ alert.buttons[$0] }).first(where: { $0.exists }) else {
                XCTFail("Botones del diálogo: \(alert.buttons.allElementsBoundByIndex.map(\.label))")
                return
            }
            waitUntil(button, "isHittable == true")
            button.tap()
            if alert.waitForNonExistence(timeout: 3) { return }
        }
        XCTAssertFalse(alert.exists, "El diálogo TCC no se cerró tras 3 taps")
    }
}
