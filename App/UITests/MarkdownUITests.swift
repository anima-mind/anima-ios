// MarkdownUITests.swift — el markdown de bloques en el chat (batch 5b #2): el
// mensaje real del dueño (título, tabla, listas, cita) renderizado en el
// simulador. Deja un screenshot como adjunto del .xcresult y, si el entorno
// trae UITEST_SNAPSHOT_DIR, también como markdown.png en esa carpeta.

import XCTest

final class MarkdownUITests: AnimaUITestCase {
    @MainActor
    func testPlanMensualRendersHeadingsTableAndLists() throws {
        let app = launch()
        onboard(app)
        send(app, "muéstrame el plan en markdown")

        let message = assistantMessage(app, value: "done", labelContains: "Plan mensual de ahorro")
        waitFor(message, timeout: 20)
        // El mensaje se lee como UN elemento (VoiceOver): su label es el texto ya
        // renderizado — sin "##", sin pipes ni la fila separadora de la tabla.
        let label = message.label
        XCTAssertFalse(label.contains("#"), label)
        XCTAssertFalse(label.contains("|"), label)
        XCTAssertFalse(label.contains("**"), label)
        for piece in ["📅 Plan mensual de ahorro", "Para aterrizarlo…", "MES", "ACUMULADO", "Diciembre",
                      "$2.700.000", "domicilios", "Lo que no se mide no se mejora."] {
            XCTAssertTrue(label.contains(piece), "falta \(piece) en: \(label)")
        }

        // El mensaje entero en pantalla para el screenshot.
        for _ in 0..<3 where message.frame.minY < 0 { app.swipeDown() }
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "markdown"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["UITEST_SNAPSHOT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("markdown.png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try shot.pngRepresentation.write(to: url)
        }
    }
}
