// WidgetsUITests.swift — batch 9: screenshots de cada widget (galería con las
// mismas vistas de la extensión) y smoke de los deep links que abren los
// widgets: recordatorio → Recordatorios, meta → Metas, control → chat con mic.

import XCTest

final class WidgetsUITests: AnimaUITestCase {
    static let widgets = [
        "widget.today.small", "widget.today.small.empty", "widget.today.medium", "widget.today.medium.empty",
        "widget.goal.small", "widget.goal.small.empty",
        "widget.lock.inline", "widget.lock.rectangular", "widget.lock.rectangular.empty", "widget.lock.circular",
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
        waitUntil(app.tabBars.buttons["Recordatorios"], "isSelected == true")

        app.open(try XCTUnwrap(URL(string: "anima://goals")))
        waitUntil(app.tabBars.buttons["Metas"], "isSelected == true")

        app.open(try XCTUnwrap(URL(string: "anima://chat")))
        waitUntil(app.tabBars.buttons["Chat"], "isSelected == true")

        openTab(app, "Metas")
        // "Hablar con Anima" (control / botón de Acción): chat + mic escuchando.
        app.open(try XCTUnwrap(URL(string: "anima://chat?mic=1")))
        waitUntil(app.tabBars.buttons["Chat"], "isSelected == true")
        waitFor(element(app, "chat.listeningBar"), timeout: 30)
    }
}
