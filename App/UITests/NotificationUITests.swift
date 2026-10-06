// NotificationUITests.swift — el tap al push de un recordatorio de Anima abre el
// Chat con la card del recordatorio, sin crash, en los tres estados del proceso:
// terminado (cold launch desde la notificación), en background y al frente.
// Notificaciones REALES del simulador: `--uitest-sticky` mantiene el modo
// UI-test aunque el sistema lance la app sin argumentos.

import XCTest

final class NotificationUITests: AnimaUITestCase {
    static let seedFlag = "--uitest-seed-reminder="
    static let stickyFlag = "--uitest-sticky"
    static let leadSeconds = 20
    static let reminderTitle = "Anima"

    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    /// Onboarding limpio y relanzamiento con el recordatorio sembrado a +20 s.
    @MainActor
    private func launchWithSeededReminder() -> XCUIApplication {
        let first = makeApp(reset: true)
        first.launchArguments.append(Self.stickyFlag)
        first.launch()
        onboard(first)
        first.terminate()

        let app = makeApp(reset: false)
        app.launchArguments += [Self.stickyFlag, "\(Self.seedFlag)\(Self.leadSeconds)"]
        app.launch()
        allowNotificationsIfAsked()
        waitForChat(app)
        return app
    }

    /// El permiso del sistema (springboard) la primera vez que Anima programa algo.
    @MainActor
    private func allowNotificationsIfAsked() {
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: scaled(8)) else { return }
        for label in ["Allow", "Permitir"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            return
        }
    }

    /// El banner de la notificación (o su fila en el centro de notificaciones).
    @MainActor
    private func notificationBanner() -> XCUIElement {
        springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Cita médica de prueba")).firstMatch
    }

    @MainActor
    private func tapNotification(timeout: TimeInterval) {
        let banner = notificationBanner()
        if !banner.waitForExistence(timeout: scaled(timeout)) {
            // El banner ya se fue: el centro de notificaciones lo conserva.
            let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.005))
            top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)))
            XCTAssertTrue(banner.waitForExistence(timeout: scaled(10)), "No llegó la notificación del recordatorio")
        }
        banner.tap()
    }

    @MainActor
    private func assertOpensReminderCard(_ app: XCUIApplication) {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: scaled(20)), "La app no quedó al frente")
        waitFor(app.textFields["chat.input"], timeout: 30)
        let card = element(app, "chat.proactive.reminder")
        waitFor(card, timeout: 20)
        XCTAssertEqual(app.state, .runningForeground, "La app murió tras abrir el recordatorio")
    }

    @MainActor
    func testTapOnReminderCold() {
        let app = launchWithSeededReminder()
        app.terminate()
        tapNotification(timeout: TimeInterval(Self.leadSeconds + 30))
        assertOpensReminderCard(app)
    }

    @MainActor
    func testTapOnReminderBackground() {
        let app = launchWithSeededReminder()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: scaled(10))
                      || app.wait(for: .runningBackgroundSuspended, timeout: scaled(10)))
        tapNotification(timeout: TimeInterval(Self.leadSeconds + 30))
        assertOpensReminderCard(app)
    }

    @MainActor
    func testTapOnReminderForeground() {
        let app = launchWithSeededReminder()
        let banner = notificationBanner()
        XCTAssertTrue(banner.waitForExistence(timeout: scaled(TimeInterval(Self.leadSeconds + 30))),
                      "Con la app al frente el recordatorio debe mostrarse como banner")
        banner.tap()
        assertOpensReminderCard(app)
    }
}
