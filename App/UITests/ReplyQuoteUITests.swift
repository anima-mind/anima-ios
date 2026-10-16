// ReplyQuoteUITests.swift — "responder citando" (reply estilo WhatsApp): el tap
// en un recordatorio PROGRAMADO abre el chat con la cita en el composer y el
// foco listo; al enviar, la burbuja la muestra. "Hablar de esta meta" cita la
// meta. Deslizar a la derecha (o mantener → "Responder") cita un mensaje y la
// X la quita.

import XCTest

final class ReplyQuoteUITests: AnimaUITestCase {
    static let seededReminder = "Cita médica de prueba"

    @MainActor
    private func composerQuote(_ app: XCUIApplication) -> XCUIElement { element(app, "chat.quote.text") }

    @MainActor
    private func waitForFocus(_ app: XCUIApplication) {
        waitUntil(app.textFields["chat.input"], "hasKeyboardFocus == true")
    }

    @MainActor
    func testTapScheduledReminderOpensChatQuotedAndTheBubbleShowsIt() {
        let app = makeApp(reset: true)
        app.launchArguments.append("--uitest-seed-reminder=3600")
        app.launch()
        onboard(app)

        openTab(app, "Recordatorios")
        let item = element(app, "reminders.item")
        tap(item)
        waitTabSelected(app, "Chat")
        let quote = composerQuote(app)
        waitUntil(quote, "label CONTAINS 'Respondiendo a recordatorio \(Self.seededReminder)'")
        XCTAssertTrue(quote.label.contains("Oye, ya casi es tu cita médica de prueba."), quote.label)
        waitForFocus(app)
        screenshot(app, "cita-recordatorio-composer")

        app.textFields["chat.input"].typeText("¿la puedes pasar al viernes?")
        tap(app.buttons["chat.send"])
        let bubbleQuote = element(app, "chat.userMessage.quote")
        waitUntil(bubbleQuote, "label CONTAINS 'Recordatorio · \(Self.seededReminder)'")
        waitFor(app.staticTexts.matching(identifier: "chat.userMessage")
            .matching(NSPredicate(format: "label == '¿la puedes pasar al viernes?'")).firstMatch)
        // Enviada, la cita deja el composer.
        waitUntil(element(app, "chat.quote.composer"), "exists == false")
        waitFor(assistantMessage(app, value: "done", labelContains: fixedReply), timeout: 20)
        screenshot(app, "cita-recordatorio-burbuja")

        // Relanzar: la burbuja vuelve con su cita (persistida con el turno).
        app.terminate()
        let relaunched = launch(reset: false)
        waitForChat(relaunched)
        waitUntil(element(relaunched, "chat.userMessage.quote"), "label CONTAINS '\(Self.seededReminder)'")
    }

    @MainActor
    func testTalkAboutThisGoalOpensChatWithTheGoalQuoted() {
        let app = makeApp(reset: true)
        app.launchArguments.append(GoalsUITests.seedFlag)
        app.launch()
        onboard(app)

        openTab(app, "Metas")
        let talk = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'goal.talk.'")).firstMatch
        tap(talk)
        waitTabSelected(app, "Chat")
        waitUntil(composerQuote(app), "label BEGINSWITH 'Respondiendo a meta Ahorrar 10 millones para invertir'")
        waitForFocus(app)
        screenshot(app, "cita-meta-composer")
    }

    @MainActor
    func testSwipeToReplyQuotesABubbleAndTheXRemovesIt() {
        let app = launch()
        onboard(app)
        send(app, "hola")
        let reply = assistantMessage(app, value: "done", labelContains: fixedReply)
        waitFor(reply, timeout: 20)

        // Deslizar a la derecha sobre el mensaje de Anima → su cita en el composer.
        reply.swipeRight()
        let quote = composerQuote(app)
        waitUntil(quote, "label BEGINSWITH 'Respondiendo a mensaje de Anima'")
        XCTAssertTrue(quote.label.contains("Te escucho"), quote.label)
        screenshot(app, "cita-swipe")
        tap(app.buttons["nav.close.quote"])
        waitUntil(element(app, "chat.quote.composer"), "exists == false")

        // Mantener presionado → "Responder" sobre la burbuja del dueño.
        let mine = app.staticTexts.matching(identifier: "chat.userMessage")
            .matching(NSPredicate(format: "label == 'hola'")).firstMatch
        waitFor(mine)
        mine.press(forDuration: 1.2)
        tap(app.buttons["Responder"])
        waitUntil(composerQuote(app), "label == 'Respondiendo a mensaje de Tú: hola'")
        tap(app.buttons["nav.close.quote"])
        waitUntil(element(app, "chat.quote.composer"), "exists == false")
        // Un scroll vertical normal no cita nada.
        element(app, "chat.messages").swipeDown()
        XCTAssertFalse(element(app, "chat.quote.composer").exists)
    }
}
