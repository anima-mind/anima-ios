// SettingsUITests.swift — Ajustes como hub (FIX F): filas con resumen vivo que
// pushean sub-pantallas. Modelo (los 3 modos, availability fake = disponible),
// Cuenta con el mock (sin cuenta), "Repetir onboarding" y el taller de skills.

import XCTest

final class SettingsUITests: AnimaUITestCase {

    /// 7. Modo, Cuenta y Repetir onboarding.
    @MainActor
    func testSettingsModeAccountAndReplay() {
        let app = launch()
        // Con token (camino Anthropic) los 3 modos son elegibles.
        onboard(app, provider: .anthropic(key: "sk-ant-api03-test"))
        openTab(app, "Ajustes")

        // Hub: una fila por sección con su resumen vivo.
        for section in ["account", "model", "skills", "glasses", "mind"] {
            waitFor(element(app, "settings.hub.\(section)"))
        }
        XCTAssertTrue(element(app, "settings.hub.model").label.contains("Claude"),
                      "modelo: \(element(app, "settings.hub.model").label)")
        XCTAssertTrue(element(app, "settings.hub.mind").label.contains("ciclo #0"),
                      "mente: \(element(app, "settings.hub.mind").label)")
        tap(element(app, "settings.hub.model"))

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
        app.navigationBars.buttons.firstMatch.tap()   // ← Ajustes
        XCTAssertTrue(element(app, "settings.hub.account").label.contains("Sin cuenta"))
        tap(element(app, "settings.hub.account"))
        let status = element(app, "settings.account.status")
        waitFor(status)
        XCTAssertTrue(status.label.contains("Sin cuenta"), "cuenta: \(status.label)")
        XCTAssertTrue(element(app, "account.appleSignIn").exists)

        // Repetir onboarding (Ajustes → Mente) → vuelve al flujo (entra directo al primer paso).
        app.navigationBars.buttons.firstMatch.tap()   // ← Ajustes
        tap(element(app, "settings.hub.mind"))
        let replay = app.buttons["settings.replayOnboarding"]
        scrollTo(replay, in: app)
        // La fila es un Button .plain sin contentShape: solo el texto recibe el
        // tap (el centro es un Spacer), así que se toca sobre la etiqueta.
        let title = text(app, "Qué es Anima")
        for _ in 0..<3 where !title.exists {
            waitUntil(replay, "isHittable == true")
            replay.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
            _ = title.waitForExistence(timeout: scaled(3))
        }
        waitFor(title)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }

    /// FIX A: Ajustes → Skills → "Enséñame algo" → conversación → borrador vivo →
    /// Guardar → la skill aparece en la lista (sesión efímera, provider guionado).
    @MainActor
    func testTeachSkillConversationallyAppearsInList() {
        let app = launch()
        onboard(app)
        openSettings(app, "skills")

        waitFor(element(app, "skills.explainer"))
        // "Ver ejemplo": el markdown de una seed en un sheet de solo lectura.
        tap(element(app, "skills.example"))
        waitFor(element(app, "skills.exampleSheet"))
        tap(app.buttons["nav.close.skillExample"])
        waitUntil(element(app, "skills.exampleSheet"), "exists == false")

        XCTAssertFalse(element(app, "skills.row.regar-plantas").exists)
        tap(element(app, "skills.new"))
        waitFor(element(app, "workshop.screen"))
        waitFor(text(app, "Enséñame algo. ¿Qué quieres que aprenda a hacer?"))

        let input = app.textFields["workshop.input"]
        tap(input)
        input.typeText("Regar las plantas de la casa")
        tap(app.buttons["workshop.send"])

        // El borrador vivo (card colapsable) + la siguiente pregunta.
        waitFor(element(app, "workshop.draft"), timeout: 20)
        waitFor(text(app, "¿Algo más o lo cambio?"))
        let save = element(app, "workshop.save")
        waitFor(save)
        tap(save)

        // De vuelta en la lista: la skill nueva aparece al instante (hot-reload).
        waitFor(element(app, "skills.row.regar-plantas"), timeout: 10)
        XCTAssertFalse(element(app, "workshop.screen").exists)
    }

    /// Campo batch 6: Ajustes → Gafas con botones de verdad (sin gafas en
    /// `--uitest`: runtime nulo), selector de iconos y diagnóstico copiable.
    @MainActor
    func testGlassesSettingsActionsAndDiagnostics() {
        let app = launch()
        onboard(app)
        openSettings(app, "glasses")

        let pair = app.buttons["settings.glasses.pair"]
        waitFor(pair)
        XCTAssertTrue(pair.label.contains("Vincular gafas"), "vincular: \(pair.label)")
        XCTAssertGreaterThanOrEqual(pair.frame.height, 44)
        XCTAssertGreaterThan(pair.frame.width, 200)
        waitFor(element(app, "settings.glasses.sdk"))
        XCTAssertTrue(element(app, "settings.glasses.sdk").label.contains("1.0.0"))
        waitFor(element(app, "settings.glasses.iconMode"))
        // Firmware y app DAT: SIEMPRE visibles (no solo con needsDATUpdate).
        XCTAssertTrue(app.buttons["settings.glasses.firmwareUpdate"].exists)
        XCTAssertTrue(app.buttons["settings.glasses.datUpdate"].exists)
        XCTAssertFalse(app.buttons["settings.glasses.unpair"].exists)

        tap(pair)
        waitUntil(element(app, "settings.glasses.notice"), "label CONTAINS 'No se pudo vincular'")

        let disclosure = element(app, "settings.glasses.diagnostics")
        scrollTo(disclosure, in: app)
        tap(disclosure)
        let copy = app.buttons["settings.glasses.copyDiagnostics"]
        scrollTo(copy, in: app)
        tap(copy)
        let notice = element(app, "settings.glasses.notice")
        scrollTo(notice, in: app)
        waitUntil(notice, "label BEGINSWITH 'Diagnóstico copiado'")
    }
}
