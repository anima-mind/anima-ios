// CarPlayUITests.swift — un turno de CarPlay llega al chat con el chip "CarPlay".
// XCUITest no maneja la pantalla del carro: `--uitest-carplay-turn` corre la
// MISMA conversación (AppModel.carPlayConversation) con voz guionada al
// terminar el cableado, como si el dueño hubiera dicho "hola por voz" en el carro.

import XCTest

final class CarPlayUITests: AnimaUITestCase {
    @MainActor
    func testCarPlayTurnLandsInTheChatWithItsChip() {
        let app = makeApp()
        app.launch()
        onboard(app)
        app.terminate()

        let again = makeApp(reset: false)
        again.launchArguments.append("--uitest-carplay-turn")
        again.launch()
        waitForChat(again)
        let asked = again.staticTexts.matching(identifier: "chat.userMessage")
            .matching(NSPredicate(format: "label == 'hola por voz'")).firstMatch
        waitFor(asked)
        waitFor(element(again, "chat.userMessage.carplay"))
        waitFor(assistantMessage(again, labelContains: fixedReply))
        screenshot(again, "carplay-01-turno-en-el-chat")
    }
}
