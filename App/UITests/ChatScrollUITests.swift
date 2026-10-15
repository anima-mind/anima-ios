// ChatScrollUITests.swift — batch 10 #1: el chat sigue el fondo mientras Anima
// responde (sin scroll manual) y, si el dueño sube a leer a mitad del stream,
// no lo jala; al volver al fondo, el seguimiento se retoma. La respuesta larga
// del provider guionado se PAUSA tras "Punto 21:" y "Punto 33:" hasta que el
// test la suelta (notificación Darwin): nada depende del reloj del runner.

import XCTest

/// Último renglón de la respuesta larga del provider guionado (UITestScriptedProvider.longReplyEnd).
let longReplyEnd = "Fin de la respuesta larga."

final class ChatScrollUITests: AnimaUITestCase {

    @MainActor
    private func list(_ app: XCUIApplication) -> XCUIElement {
        element(app, "chat.messages")
    }

    /// Suelta la pausa en curso del stream (UITestStreamGate de la app).
    private func resumeStream() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("com.joshuamoreno1.anima.uitest.stream.resume" as CFString),
                                             nil, nil, true)
    }

    /// El stream está quieto en la pausa que sigue a `marker` (sin el párrafo siguiente).
    @MainActor
    private func pausedAt(_ app: XCUIApplication, _ marker: String, next: String) -> XCUIElement {
        let message = assistantMessage(app, value: "streaming", labelContains: marker)
        waitFor(message, timeout: 60)
        XCTAssertFalse(assistantMessage(app, labelContains: next).exists, "el stream no se pausó en \(marker)")
        return message
    }

    /// El borde inferior del mensaje está dentro de la lista visible (±2 pt).
    @MainActor
    private func bottomIsVisible(_ message: XCUIElement, in list: XCUIElement) -> Bool {
        let frame = message.frame, visible = list.frame
        return frame.maxY <= visible.maxY + 2 && frame.maxY >= visible.minY
    }

    /// Con el contenido quieto, el scroll pendiente se asienta: se re-lee hasta verlo.
    @MainActor
    private func assertBottomVisible(_ message: XCUIElement, in list: XCUIElement, _ context: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(scaled(5))
        while !bottomIsVisible(message, in: list), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(bottomIsVisible(message, in: list), "\(context): \(message.frame) fuera de \(list.frame)",
                      file: file, line: line)
    }

    @MainActor
    func testLongReplyFollowsTheBottomWhileStreaming() {
        let app = launch()
        onboard(app)
        send(app, "dame una respuesta larga")
        let messages = list(app)

        // Pausa 1: ya desbordó (~2 pantallas) y el final sigue a la vista sin scroll manual.
        let first = pausedAt(app, "Punto 21:", next: "Punto 22:")
        XCTAssertGreaterThan(first.frame.height, messages.frame.height, "la respuesta debe desbordar")
        assertBottomVisible(first, in: messages, "pausa 1")
        resumeStream()
        assertBottomVisible(pausedAt(app, "Punto 33:", next: "Punto 34:"), in: messages, "pausa 2")
        resumeStream()

        let done = assistantMessage(app, value: "done", labelContains: longReplyEnd)
        waitFor(done, timeout: 60)
        assertBottomVisible(done, in: messages, "al terminar")
        screenshot(app, "batch10-01-sigue-el-fondo")
    }

    @MainActor
    func testScrollingUpMidStreamIsNotYankedAndFollowingResumesAtTheBottom() {
        let app = launch()
        onboard(app)
        send(app, "otra respuesta larga")
        let messages = list(app)

        // Pausa 1 (ya desbordó de sobra, más allá del margen de 80 pt): el dueño sube a leer.
        _ = pausedAt(app, "Punto 21:", next: "Punto 22:")
        for _ in 0..<6 where !app.staticTexts.matching(identifier: "chat.userMessage").firstMatch.isHittable {
            messages.swipeDown()
        }
        let user = app.staticTexts.matching(identifier: "chat.userMessage")
            .matching(NSPredicate(format: "label == 'otra respuesta larga'")).firstMatch
        waitUntil(user, "isHittable == true")
        let pinned = user.frame.minY

        // Llegan 12 párrafos más mientras está arriba: la vista no se mueve.
        resumeStream()
        let streaming = pausedAt(app, "Punto 33:", next: "Punto 34:")
        XCTAssertEqual(user.frame.minY, pinned, accuracy: 2, "el chat jaló al dueño hacia abajo")
        XCTAssertFalse(bottomIsVisible(streaming, in: messages))

        // Vuelve al fondo a mano (con el stream quieto) y desde ahí lo sigue solo.
        for _ in 0..<12 where !bottomIsVisible(streaming, in: messages) {
            messages.swipeUp()
        }
        assertBottomVisible(streaming, in: messages, "de vuelta al fondo")
        resumeStream()
        let done = assistantMessage(app, value: "done", labelContains: longReplyEnd)
        waitFor(done, timeout: 60)
        assertBottomVisible(done, in: messages, "al terminar")
    }
}
