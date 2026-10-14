// ChatScrollUITests.swift — batch 10 #1: el chat sigue el fondo mientras Anima
// responde (sin scroll manual) y, si el dueño sube a leer a mitad del stream,
// no lo jala; al volver al fondo, el seguimiento se retoma.

import XCTest

/// Último renglón de la respuesta larga del provider guionado (UITestScriptedProvider.longReplyEnd).
let longReplyEnd = "Fin de la respuesta larga."

final class ChatScrollUITests: AnimaUITestCase {

    @MainActor
    private func list(_ app: XCUIApplication) -> XCUIElement {
        element(app, "chat.messages")
    }

    /// El borde inferior del mensaje está dentro de la lista visible.
    @MainActor
    private func bottomIsVisible(_ message: XCUIElement, in list: XCUIElement) -> Bool {
        let frame = message.frame, visible = list.frame
        return frame.maxY <= visible.maxY + 2 && frame.maxY >= visible.minY
    }

    @MainActor
    func testLongReplyFollowsTheBottomWhileStreaming() {
        let app = launch()
        onboard(app)
        send(app, "dame una respuesta larga")
        let messages = list(app)

        // A mitad del stream (ya desbordó la pantalla): el final sigue a la vista.
        let streaming = assistantMessage(app, value: "streaming", labelContains: "Punto 20:")
        waitFor(streaming, timeout: 20)
        XCTAssertTrue(bottomIsVisible(streaming, in: messages),
                      "a mitad del stream: \(streaming.frame) fuera de \(messages.frame)")

        let done = assistantMessage(app, value: "done", labelContains: longReplyEnd)
        waitFor(done, timeout: 30)
        XCTAssertGreaterThan(done.frame.height, messages.frame.height, "la respuesta debe desbordar")
        XCTAssertTrue(bottomIsVisible(done, in: messages), "al terminar: \(done.frame) fuera de \(messages.frame)")
        screenshot(app, "batch10-01-sigue-el-fondo")
    }

    @MainActor
    func testScrollingUpMidStreamIsNotYankedAndFollowingResumesAtTheBottom() {
        let app = launch()
        onboard(app)
        send(app, "otra respuesta larga")
        let messages = list(app)

        waitFor(assistantMessage(app, value: "streaming", labelContains: "Punto 10:"), timeout: 20)
        messages.swipeDown()
        messages.swipeDown()

        // Ya arriba: mientras sigue llegando texto, la vista no se mueve.
        let user = app.staticTexts.matching(identifier: "chat.userMessage")
            .matching(NSPredicate(format: "label == 'otra respuesta larga'")).firstMatch
        waitUntil(user, "isHittable == true")
        let pinned = user.frame.minY
        waitFor(assistantMessage(app, value: "streaming", labelContains: "Punto 20:"), timeout: 20)
        XCTAssertEqual(user.frame.minY, pinned, accuracy: 2, "el chat jaló al dueño hacia abajo")
        let streaming = assistantMessage(app, value: "streaming")
        XCTAssertFalse(bottomIsVisible(streaming, in: messages))

        // Vuelve al fondo a mano: desde ahí el stream lo sigue solo hasta el final.
        for _ in 0..<8 where streaming.exists && !bottomIsVisible(streaming, in: messages) {
            messages.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(streaming.exists, "el stream terminó antes de volver al fondo")
        let done = assistantMessage(app, value: "done", labelContains: longReplyEnd)
        waitFor(done, timeout: 30)
        XCTAssertTrue(bottomIsVisible(done, in: messages), "al terminar: \(done.frame) fuera de \(messages.frame)")
    }
}
