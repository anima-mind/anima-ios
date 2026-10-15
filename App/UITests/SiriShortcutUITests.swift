// SiriShortcutUITests.swift — batch 10 #2: "Pregúntale a Anima" desde la app
// Atajos con la app CERRADA. El intent corre en el proceso de la app lanzada en
// background (modo UI-test persistido con --uitest-sticky), responde con la
// respuesta del turno y el turno queda en el chat con el chip "Siri".
// linkd solo ejecuta App Shortcuts de un binario con team ID: con la firma
// ad-hoc de scripts/ui-test.sh el sistema lo rechaza y el test se salta.

import XCTest

final class SiriShortcutUITests: AnimaUITestCase {
    @MainActor
    func testAskAnimaShortcutRunsATurnWithoutOpeningTheApp() throws {
        let app = makeApp()
        app.launchArguments.append("--uitest-sticky")
        app.launch()
        onboard(app)
        app.terminate()

        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        shortcuts.launch()
        tap(shortcuts.otherElements["Pregúntale a Anima"].firstMatch)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let prompt = springboard.staticTexts["¿Qué le quieres decir a Anima?"]
        let rejected = shortcuts.alerts["No se puede ejecutar el atajo de la app"]
        _ = prompt.waitForExistence(timeout: scaled(15))
        if !prompt.exists, rejected.exists {
            throw XCTSkip("linkd rechaza el binario sin team ID (firma ad-hoc): correr con firma de equipo.")
        }
        waitFor(prompt)
        let field = springboard.textFields.firstMatch
        waitFor(field)
        field.typeText("hola desde siri")
        tap(springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Listo", "OK"])).firstMatch)

        let reply = springboard.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fixedReply)).firstMatch
        waitFor(reply, timeout: 30)
        screenshot(springboard, "batch10-02-siri-respuesta")

        let again = makeApp(reset: false)
        again.launchArguments.append("--uitest-sticky")
        again.launch()
        waitForChat(again)
        let asked = again.staticTexts.matching(identifier: "chat.userMessage")
            .matching(NSPredicate(format: "label == 'hola desde siri'")).firstMatch
        waitFor(asked)
        waitFor(element(again, "chat.userMessage.siri"))
        waitFor(assistantMessage(again, labelContains: fixedReply))
        screenshot(again, "batch10-03-siri-en-el-chat")
    }
}
