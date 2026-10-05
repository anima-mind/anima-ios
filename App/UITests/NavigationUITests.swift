// NavigationUITests.swift — campo #8: sin callejones en el teléfono. El teclado
// del chat se cierra (tap en mensajes / al enviar) y la tab bar vuelve; cada
// superficie alcanzable tiene una salida visible que deja el TabView usable.

import XCTest

final class NavigationUITests: AnimaUITestCase {

    @MainActor
    func keyboardIsUp(_ app: XCUIApplication) -> Bool { app.keyboards.firstMatch.exists }

    /// El caso que el dueño sufría: teclado arriba = tab bar enterrada.
    @MainActor
    func testChatKeyboardDismissesAndThoughtLineStillWorks() {
        let app = launch()
        onboard(app)
        send(app, "hola")
        waitFor(assistantMessage(app, value: "done", labelContains: fixedReply), timeout: 15)
        // Enviar cierra el teclado solo.
        waitUntil(app.keyboards.firstMatch, "exists == false")

        // Teclado arriba → la thought line sigue expandiéndose con un tap.
        tap(app.textFields["chat.input"])
        waitFor(app.keyboards.firstMatch)
        let thought = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pensó'")).firstMatch
        tap(thought)
        waitFor(text(app, "Saludo breve. Respondo en modo de prueba."))

        // Teclado arriba → tap en un mensaje lo cierra y la tab bar vuelve a ser tocable.
        tap(app.textFields["chat.input"])
        waitFor(app.keyboards.firstMatch)
        assistantMessage(app, value: "done").tap()
        waitUntil(app.keyboards.firstMatch, "exists == false")
        let settingsTab = app.tabBars.buttons["Ajustes"]
        waitUntil(settingsTab, "isHittable == true")
    }

    /// Cada superficie alcanzable tiene salida y el TabView sigue accesible.
    @MainActor
    func testEverySurfaceHasAVisibleExit() {
        let app = launch()
        onboard(app)

        // Mind sheet → X.
        tap(app.buttons["chat.plasticityBadge"])
        waitFor(element(app, "mind.sheet"))
        tap(app.buttons["nav.close.mind"])
        waitUntil(element(app, "mind.sheet"), "exists == false")
        waitUntil(app.tabBars.buttons["Memoria"], "isHittable == true")

        // Tabs: cada una deja la tab bar usable.
        for tab in ["Memoria", "Metas", "Aprobaciones", "Ajustes", "Chat"] {
            openTab(app, tab)
            waitUntil(app.tabBars.buttons[tab], "isSelected == true")
        }

        // Repetir onboarding desde Ajustes → Mente → abandonarlo a mitad con la X → de vuelta en Ajustes.
        openSettings(app, "mind")
        let replay = app.buttons["settings.replayOnboarding"]
        scrollTo(replay, in: app)
        let title = text(app, "Qué es Anima")
        for _ in 0..<3 where !title.exists {
            waitUntil(replay, "isHittable == true")
            replay.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
            _ = title.waitForExistence(timeout: scaled(3))
        }
        waitFor(title)
        tap(app.buttons["onboarding.next"])
        waitFor(text(app, "Tu cuenta"))
        tap(app.buttons["nav.close.onboarding"])
        waitFor(app.tabBars.firstMatch)
        waitUntil(app.tabBars.buttons["Ajustes"], "isSelected == true")
        XCTAssertFalse(app.buttons["landing.begin"].exists)
    }
}
