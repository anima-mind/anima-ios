// SettingsUITests.swift — Ajustes: los 3 modos (availability fake = disponible),
// la sección Cuenta con el mock (sin cuenta) y "Repetir onboarding".

import XCTest

final class SettingsUITests: AnimaUITestCase {

    /// 7. Modo, Cuenta y Repetir onboarding.
    @MainActor
    func testSettingsModeAccountAndReplay() {
        let app = launch()
        // Con token (camino Anthropic) los 3 modos son elegibles.
        onboard(app, provider: .anthropic(key: "sk-ant-api03-test"))
        openTab(app, "Ajustes")

        let onDevice = app.buttons["settings.mode.on_device_only"]
        let claude = app.buttons["settings.mode.claude"]
        let hybrid = app.buttons["settings.mode.hybrid"]
        [onDevice, claude, hybrid].forEach { waitFor($0) }
        // El onboarding con key + modelo local disponible deja Híbrido.
        waitUntil(hybrid, "isSelected == true")

        tap(claude, until: claude, "isSelected == true")
        XCTAssertFalse(hybrid.isSelected)

        tap(onDevice, until: onDevice, "isSelected == true")
        XCTAssertFalse(claude.isSelected)
        XCTAssertFalse(element(app, "settings.mode.notice").exists)

        tap(hybrid, until: hybrid, "isSelected == true")

        // Cuenta (PreviewAccountProvider, signedOut): "Sin cuenta" + Sign in with Apple.
        let status = element(app, "settings.account.status")
        waitFor(status)
        XCTAssertTrue(status.label.contains("Sin cuenta"), "cuenta: \(status.label)")
        XCTAssertTrue(element(app, "account.appleSignIn").exists)

        // Repetir onboarding → vuelve al flujo (entra directo al primer paso).
        let replay = app.buttons["settings.replayOnboarding"]
        scrollTo(replay, in: app)
        // La fila es un Button .plain sin contentShape: solo el texto recibe el
        // tap (el centro es un Spacer), así que se toca sobre la etiqueta.
        let title = text(app, "Qué es Anima")
        for _ in 0..<3 where !title.exists {
            waitUntil(replay, "isHittable == true")
            replay.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
            _ = title.waitForExistence(timeout: 3)
        }
        waitFor(title)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }
}
