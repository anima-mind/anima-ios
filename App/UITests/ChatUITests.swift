// ChatUITests.swift — un turno end-to-end contra el provider guionado del modo
// --uitest (sin modelo real ni token) y el Mind sheet desde el badge.

import XCTest

final class ChatUITests: AnimaUITestCase {

    /// 4. Turno: "hola" → streaming (caret) → respuesta fija → queda en la lista.
    @MainActor
    func testChatTurnStreamsFixedReply() {
        let app = launch()
        onboard(app)

        send(app, "hola")

        let userBubble = app.staticTexts.matching(identifier: "chat.userMessage")
            .matching(NSPredicate(format: "label == 'hola'")).firstMatch
        waitFor(userBubble)

        // Mientras streamea: value "streaming" (el caret está en pantalla).
        waitFor(assistantMessage(app, value: "streaming"), timeout: 10)

        // Al terminar: la respuesta fija completa y el turno cerrado.
        let done = assistantMessage(app, value: "done", labelContains: fixedReply)
        waitFor(done, timeout: 15)
        XCTAssertFalse(assistantMessage(app, value: "streaming").exists)
        XCTAssertTrue(userBubble.exists)

        // El composer vuelve a estar listo para otro turno.
        XCTAssertTrue(app.textFields["chat.input"].isEnabled)
    }

    /// 8. Mind sheet: tap al badge de plasticidad → mark + key/values.
    @MainActor
    func testPlasticityBadgeOpensMindSheet() {
        let app = launch()
        onboard(app)

        let badge = app.buttons["chat.plasticityBadge"]
        waitFor(badge)
        XCTAssertTrue(badge.label.contains("infancia"), "badge: \(badge.label)")
        tap(badge)

        waitFor(element(app, "mind.sheet"))
        waitFor(element(app, "mind.mark"))
        waitFor(text(app, "0 noches de consolidación"))

        let body = element(app, "mind.row.body")
        let regime = element(app, "mind.row.regime")
        let cycles = element(app, "mind.row.cycles")
        waitFor(body)
        XCTAssertTrue(body.label.contains("solo teléfono"), "cuerpo: \(body.label)")
        XCTAssertTrue(regime.label.contains("infancia"), "régimen: \(regime.label)")
        XCTAssertTrue(cycles.label.contains("0"), "ciclos: \(cycles.label)")
    }
}
