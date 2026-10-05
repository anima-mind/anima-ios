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

        // Campo #10: cerrar y reabrir (sin reset) NO deja el chat vacío.
        app.terminate()
        let relaunched = launch(reset: false)
        waitForChat(relaunched)
        waitFor(relaunched.staticTexts.matching(identifier: "chat.userMessage")
            .matching(NSPredicate(format: "label == 'hola'")).firstMatch)
        waitFor(assistantMessage(relaunched, labelContains: fixedReply))
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

    /// Campo #9: mic del composer → listening bar → transcript → turno de voz en el chat.
    @MainActor
    func testComposerMicSendsVoiceTurn() {
        let app = launch()
        onboard(app)

        tap(app.buttons["chat.mic"])
        waitFor(element(app, "chat.listeningBar"))
        waitFor(text(app, "Escuchando…"))
        waitFor(element(app, "chat.listening.transcript"))
        // Fin por silencio (voz guionada ≈1.5 s): la barra se va y el turno entra.
        let bubble = app.staticTexts.matching(identifier: "chat.userMessage")
            .matching(NSPredicate(format: "label == 'hola por voz'")).firstMatch
        waitFor(bubble)
        waitFor(element(app, "chat.userMessage.voice"))
        waitUntil(element(app, "chat.listeningBar"), "exists == false")
        waitFor(assistantMessage(app, value: "done", labelContains: fixedReply), timeout: 15)

        // Cancelar con la X: no se envía nada nuevo.
        tap(app.buttons["chat.mic"])
        waitFor(element(app, "chat.listeningBar"))
        tap(app.buttons["nav.close.listening"])
        waitUntil(element(app, "chat.listeningBar"), "exists == false")
        XCTAssertEqual(app.staticTexts.matching(identifier: "chat.userMessage").count, 1)
    }

    /// Campo #11: cámara del composer → menú → (picker guionado) → thumb → enviar → burbuja con thumb.
    @MainActor
    func testComposerPhotoAttachesAndSends() {
        let app = launch()
        // Con modelo remoto (en Solo-teléfono el menú solo explica que hace falta uno).
        onboard(app, provider: .anthropic(key: "sk-ant-api03-test"))

        tap(app.buttons["chat.camera"])
        tap(app.buttons["Elegir de la galería"])
        waitFor(element(app, "chat.attachment"))
        // Quitar y volver a adjuntar con "Tomar foto".
        tap(app.buttons["nav.close.attachment"])
        waitUntil(element(app, "chat.attachment"), "exists == false")
        tap(app.buttons["chat.camera"])
        tap(app.buttons["Tomar foto"])
        waitFor(element(app, "chat.attachment"))

        let input = app.textFields["chat.input"]
        tap(input)
        input.typeText("mira esto")
        tap(app.buttons["chat.send"])
        waitFor(element(app, "chat.userMessage.photo"))
        waitUntil(element(app, "chat.attachment"), "exists == false")
        waitFor(assistantMessage(app, value: "done", labelContains: fixedReply), timeout: 15)
    }
}
