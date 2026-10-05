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

        // Una fila por provider (radio de activo + estado inline) + toggle Híbrido.
        let claude = app.buttons["settings.provider.anthropic.radio"]
        let local = app.buttons["settings.provider.on_device.radio"]
        let hybrid = app.switches["settings.mode.hybrid"]
        [claude, local].forEach { waitFor($0) }
        waitUntil(claude, "isSelected == true")
        XCTAssertTrue(element(app, "settings.provider.anthropic.status").label.contains("key guardada"))
        // El onboarding con key + modelo local disponible deja Híbrido.
        waitUntil(hybrid, "value == '1'")

        tap(local, until: local, "isSelected == true")
        XCTAssertFalse(claude.isSelected)
        XCTAssertFalse(hybrid.exists)   // Solo teléfono: sin Híbrido

        tap(claude, until: claude, "isSelected == true")
        waitFor(hybrid)

        // Gemini sin key: radio deshabilitado → "Agregar key" expande su campo inline.
        let geminiStatus = element(app, "settings.provider.google.status")
        waitFor(geminiStatus)
        XCTAssertTrue(geminiStatus.label.contains("sin key"))
        tap(app.buttons["settings.provider.google.action"])
        let field = app.secureTextFields["settings.provider.google.field"]
        tap(field)
        XCTAssertEqual(field.placeholderValue, "AIza…")
        XCTAssertTrue(app.buttons["settings.provider.google.save"].exists)
        field.typeText("AIzaSyUITest123\n")   // return = Guardar (el teclado tapa el botón)
        waitUntil(field, "exists == false")
        waitUntil(geminiStatus, "label CONTAINS 'key guardada'")
        XCTAssertTrue(claude.isSelected, "guardar otra key no cambia el activo")

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
