// NudgeUITests.swift — "avisos si no hablamos": el tap al aviso por inactividad
// abre el Chat con la pregunta de Anima como card, lista para responder, con la
// app terminada (cold launch) y en background. Notificaciones REALES del
// simulador: el aviso se adelanta con `--uitest-nudge-probe=N` (el mismo
// "Probar en 1 minuto" de Ajustes, a +N s) y lleva la pregunta sembrada como si
// la hubiera dejado el sueño (`--uitest-seed-nudge-question`).

import XCTest

final class NudgeUITests: AnimaUITestCase {
    static let probeFlag = "--uitest-nudge-probe="
    static let seedFlag = "--uitest-seed-nudge-question"
    static let stickyFlag = "--uitest-sticky"
    static let leadSeconds = 20
    /// = UITestMode.seededNudgeQuestion
    static let question = "¿Cómo te fue en la reunión con Pedro?"

    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    /// Onboarding limpio y relanzamiento con el aviso adelantado a +N s.
    @MainActor
    private func launchWithProbe(lead: Int = leadSeconds) -> XCUIApplication {
        let first = makeApp(reset: true)
        first.launchArguments.append(Self.stickyFlag)
        first.launch()
        onboard(first)
        first.terminate()

        let app = makeApp(reset: false)
        app.launchArguments += [Self.stickyFlag, Self.seedFlag, "\(Self.probeFlag)\(lead)"]
        app.launch()
        allowNotificationsIfAsked()
        waitForChat(app)
        return app
    }

    @MainActor
    private func allowNotificationsIfAsked() {
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: scaled(8)) else { return }
        for label in ["Allow", "Permitir"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            return
        }
    }

    @MainActor
    private func banner() -> XCUIElement {
        springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "reunión con Pedro")).firstMatch
    }

    @MainActor
    private func tapNotification(timeout: TimeInterval) {
        let banner = banner()
        if !banner.waitForExistence(timeout: scaled(timeout)) {
            let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.005))
            top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)))
            XCTAssertTrue(banner.waitForExistence(timeout: scaled(10)), "No llegó el aviso por inactividad")
        }
        banner.tap()
    }

    /// El chat al frente con la pregunta como card de Anima y el composer listo.
    @MainActor
    private func assertOpensQuestion(_ app: XCUIApplication) {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: scaled(20)), "La app no quedó al frente")
        let input = app.textFields["chat.input"]
        waitFor(input, timeout: 30)
        let card = element(app, "chat.proactive.nudge")
        waitFor(card, timeout: 20)
        XCTAssertTrue(card.staticTexts[Self.question].waitForExistence(timeout: scaled(5)),
                      "La card no trae la pregunta")
        let label = card.staticTexts["chat.proactive.label"]
        XCTAssertTrue(label.exists && label.label.hasPrefix("Pregunta de"), label.label)
        XCTAssertTrue(input.isEnabled, "El composer debe quedar listo para responder")
        XCTAssertEqual(app.state, .runningForeground, "La app murió tras abrir el aviso")
    }

    @MainActor
    func testTapOnNudgeColdOpensChatWithQuestion() {
        let app = launchWithProbe()
        app.terminate()
        tapNotification(timeout: TimeInterval(Self.leadSeconds + 30))
        assertOpensQuestion(app)
        // Un solo mensaje: el relanzamiento no la duplica.
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "chat.proactive.nudge").count, 1)
    }

    @MainActor
    func testTapOnNudgeBackgroundOpensChatWithQuestion() {
        let app = launchWithProbe()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: scaled(10))
                      || app.wait(for: .runningBackgroundSuspended, timeout: scaled(10)))
        tapNotification(timeout: TimeInterval(Self.leadSeconds + 30))
        assertOpensQuestion(app)
    }

    /// Ajustes → Notificaciones: "Avisos si no hablamos" encendido cada 3 días;
    /// elegir 5 cambia el texto de la fila.
    @MainActor
    func testSettingsRowTogglesAndPicksDays() {
        // Un solo lanzamiento (notificaciones reales): sin permiso aún, se pide aquí.
        let app = makeApp(reset: true)
        app.launchArguments.append(Self.stickyFlag)
        app.launch()
        onboard(app)
        openSettings(app, "notifications")
        let request = element(app, "settings.notifications.request")
        if request.waitForExistence(timeout: scaled(3)) {
            tap(request)
            allowNotificationsIfAsked()
        }
        let toggle = element(app, "settings.notifications.nudge")
        waitFor(toggle)
        waitUntil(toggle, "isEnabled == true")
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertEqual(toggle.value as? String, "1")
        let detail = element(app, "settings.notifications.nudge.detail")
        waitUntil(detail, "label CONTAINS '3 días'")
        tap(app.buttons["5 días"])
        waitUntil(detail, "label CONTAINS '5 días'")
        XCTAssertTrue(element(app, "settings.notifications.nudge.probe").exists)
    }
}
