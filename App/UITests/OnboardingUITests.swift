// OnboardingUITests.swift — arranque, onboarding por los dos caminos (on-device
// y Anthropic) y persistencia del estado "ya nació" entre lanzamientos.

import XCTest

final class OnboardingUITests: AnimaUITestCase {

    /// 1. Launch smoke: la app abre en el Landing sin crash.
    @MainActor
    func testLaunchShowsLanding() {
        let app = launch()
        waitFor(text(app, "ANIMA"))
        waitFor(app.buttons["landing.begin"])
        XCTAssertEqual(app.buttons["landing.begin"].label, "Dar vida a una mente")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// 2. Camino on-device: sin paso de API key; Birth completo; aterriza en Chat.
    @MainActor
    func testOnboardingOnDevicePathSkipsAPIKey() {
        let app = launch()
        startFromLanding(app)
        passTutorialAndAccount(app)
        chooseProvider(app, .onDevice)
        // Tras el provider on-device se salta directo a Permisos.
        waitFor(text(app, "Su cuerpo, con tu permiso"))
        XCTAssertFalse(text(app, "Tu API key").exists)
        XCTAssertFalse(app.textFields["onboarding.apiKey.field"].exists)
        passPermissionsAndGlasses(app)
        completeBirth(app)
        waitForChat(app)
        // Header (campo batch 5 #5): el nombre del self a la izquierda; la marca al centro.
        let header = element(app, "chat.selfName")
        waitUntil(header, "label == 'Anima'")
    }

    /// FIX D: el header muestra el NOMBRE que el dueño le dio en el Birth.
    @MainActor
    func testChatHeaderShowsSelfName() {
        let app = launch()
        onboard(app, name: "Iris")
        let header = element(app, "chat.selfName")
        waitUntil(header, "label == 'Iris'")
        XCTAssertTrue(app.buttons["chat.plasticityBadge"].exists)
        XCTAssertTrue(element(app, "chat.bodyLine").exists)
    }

    /// 3. Camino Anthropic: paso API key con validación offline (sin red en --uitest).
    @MainActor
    func testOnboardingAnthropicPathValidatesKeyOffline() {
        let app = launch()
        startFromLanding(app)
        passTutorialAndAccount(app)
        chooseProvider(app, .anthropic(key: "sk-ant-api03-test"))
        passPermissionsAndGlasses(app)
        completeBirth(app)
        waitForChat(app)
    }

    /// 5. Persistencia: relanzar SIN --uitest-reset va directo al TabView.
    @MainActor
    func testRelaunchSkipsOnboarding() {
        let first = launch()
        onboard(first)
        first.terminate()

        let second = launch(reset: false)
        waitForChat(second)
        XCTAssertFalse(second.buttons["landing.begin"].exists)
        XCTAssertFalse(text(second, "Qué es Anima").exists)
    }
}
