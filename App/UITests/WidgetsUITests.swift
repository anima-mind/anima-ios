// WidgetsUITests.swift — batch 9: screenshots de cada widget (galería con las
// mismas vistas de la extensión) y smoke de los deep links que abren los
// widgets: recordatorio → Recordatorios, meta → Metas, control / widget
// "Hablar con Anima" / mic del widget Hoy → chat con mic.

import XCTest

final class WidgetsUITests: AnimaUITestCase {
    static let widgets = [
        "widget.today.small", "widget.today.small.empty", "widget.today.medium", "widget.today.medium.empty",
        "widget.goal.small", "widget.goal.small.empty",
        "widget.lock.inline", "widget.lock.rectangular", "widget.lock.rectangular.empty", "widget.lock.circular",
        "widget.talk.small", "widget.talk.small.empty", "widget.talk.circular", "widget.talk.inline",
        "widget.control.talk", "widget.live.consolidating", "widget.live.done",
    ]

    @MainActor
    func testCaptureEveryWidget() {
        for id in Self.widgets {
            // Un lanzamiento por widget, centrado: el screenshot sale entero.
            let app = makeApp(reset: false)
            app.launchArguments.append("--uitest-widget=\(id)")
            app.launch()
            let widget = element(app, id)
            waitFor(widget)
            let attachment = XCTAttachment(screenshot: widget.screenshot())
            attachment.name = id
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        // El vacío amable, en español.
        let app = makeApp(reset: false)
        app.launchArguments.append("--uitest-widget=widget.today.small.empty")
        app.launch()
        waitFor(app.staticTexts["Nada pendiente hoy"])
    }

    /// "Hablar con Anima" en la galería: el nombre del self (o "Anima" sin
    /// snapshot) y el mic discreto del widget Hoy.
    @MainActor
    func testTalkWidgetNamesTheSelf() {
        let app = makeApp(reset: false)
        app.launchArguments.append("--uitest-widget=widget.talk.small")
        app.launch()
        waitFor(element(app, "widget.talk.small").descendants(matching: .any)["Hablar con Budosky"])

        let empty = makeApp(reset: false)
        empty.launchArguments.append("--uitest-widget=widget.talk.small.empty")
        empty.launch()
        waitFor(element(empty, "widget.talk.small.empty").descendants(matching: .any)["Hablar con Anima"])

        let today = makeApp(reset: false)
        today.launchArguments.append("--uitest-widget=widget.today.medium")
        today.launch()
        waitFor(element(today, "widget.today.medium").descendants(matching: .any)["widget.today.talk"])
    }

    @MainActor
    func testWidgetDeepLinksOpenTheirTabsAndTheMic() throws {
        let app = makeApp(reset: true)
        app.launchArguments.append("--uitest-seed-goal")
        app.launch()
        onboard(app)
        // `open(url)` relanza la app con sus launchArguments: sin reset, conserva
        // la mente nacida (el link entra en frío, como el tap a un widget).
        app.launchArguments.removeAll { $0 == "--uitest-reset" }

        app.open(try XCTUnwrap(URL(string: "anima://reminders")))
        waitTabSelected(app, "Recordatorios")

        app.open(try XCTUnwrap(URL(string: "anima://goals")))
        waitTabSelected(app, "Metas")

        app.open(try XCTUnwrap(URL(string: "anima://chat")))
        waitTabSelected(app, "Chat")

        openTab(app, "Metas")
        // "Hablar con Anima" (control / botón de Acción): chat + mic escuchando.
        app.open(try XCTUnwrap(URL(string: "anima://chat?mic=1")))
        // El mic guionado escucha ~1,2 s × escala y envía "hola por voz": vale la
        // barra en pantalla o el turno de voz que dejó (solo el mic lo produce).
        // Se mira ANTES de las aserciones de la tab: en un simulador frío cada
        // snapshot cuesta y la barra podía irse sin que el test la viera.
        let heard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", ["chat.listeningBar", "chat.userMessage.voice"]))
            .firstMatch
        waitFor(heard, timeout: 30)
        waitTabSelected(app, "Chat")
    }

    /// Lo que el mic guionado deja en pantalla: la barra o el turno de voz.
    @MainActor
    private func heard(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", ["chat.listeningBar", "chat.userMessage.voice"]))
            .firstMatch
    }

    @MainActor
    private func onboarded(_ extra: [String] = []) -> XCUIApplication {
        let app = makeApp(reset: true)
        app.launchArguments += extra
        app.launch()
        onboard(app)
        app.launchArguments.removeAll { $0 == "--uitest-reset" }
        return app
    }

    /// Campo build 27: el intent del control pedía el mic con OpenURLIntent y
    /// iOS lo rechazaba. Ahora el perform (en el proceso de la app, en frío y
    /// antes de que la escena esté activa) pide el mic sin URL.
    @MainActor
    func testTalkIntentOpensTheMicWithoutAURL() {
        let app = onboarded()
        app.terminate()
        app.launchArguments.append("--uitest-run-talk-intent")
        app.launch()
        waitFor(heard(app), timeout: 30)
        waitTabSelected(app, "Chat")
    }

    /// El deep link del widget con la app en background (caliente) y cerrada (frío).
    @MainActor
    func testTalkDeepLinkListensFromBackgroundAndCold() throws {
        let app = onboarded()
        let url = try XCTUnwrap(URL(string: "anima://chat?mic=1"))

        openTab(app, "Metas")
        XCUIDevice.shared.press(.home)
        waitUntil(app, "state == \(XCUIApplication.State.runningBackground.rawValue)"
                  + " OR state == \(XCUIApplication.State.runningBackgroundSuspended.rawValue)")
        app.open(url)
        waitFor(heard(app), timeout: 30)
        waitTabSelected(app, "Chat")
        // En frío el turno anterior sigue en el historial: vale la barra o un
        // SEGUNDO turno de voz.
        let voiceTurns = app.descendants(matching: .any).matching(identifier: "chat.userMessage.voice")
        waitFor(voiceTurns.firstMatch, timeout: 30)
        app.terminate()
        app.open(url)
        let deadline = Date().addingTimeInterval(scaled(30))
        var listened = false
        while Date() < deadline, !listened {
            listened = app.descendants(matching: .any)["chat.listeningBar"].exists || voiceTurns.count >= 2
            if !listened { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        }
        XCTAssertTrue(listened, "En frío el deep link no abrió el mic")
        waitTabSelected(app, "Chat")
    }

    /// Si el mic no abre (ni al reintentar), se dice; nunca en silencio.
    @MainActor
    func testTalkMicFailureIsVisible() throws {
        let app = onboarded(["--uitest-voice-fail"])
        app.open(try XCTUnwrap(URL(string: "anima://chat?mic=1")))
        let note = element(app, "chat.voiceError")
        waitFor(note, timeout: 30)
        XCTAssertTrue(note.label.hasPrefix("No pude abrir el micrófono"), note.label)
        XCTAssertFalse(element(app, "chat.listeningBar").exists)
        screenshot(app, "talk-mic-error")
    }
}
