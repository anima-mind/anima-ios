// MemoryUITests.swift — Memoria legible (batch 5b #10): origen "Noche #1 ·
// destilado"; "Invalidar recuerdo" (botón real, razón opcional) la pasa a
// ocultas; "Mostrar invalidadas" las despliega.

import XCTest

final class MemoryUITests: AnimaUITestCase {
    @MainActor
    func testInvalidateWithTheButtonHidesItAndTheToggleShowsIt() {
        let app = makeApp(reset: true)
        app.launchArguments.append("--uitest-seed-memory")
        app.launch()
        onboard(app)
        openTab(app, "Memoria")

        let item = element(app, "memory.item")
        waitFor(item)
        XCTAssertTrue(item.label.contains("Noche #1 · destilado"), item.label)
        XCTAssertTrue(item.label.contains("confianza 50 %"), item.label)
        tap(item, until: element(app, "memory.invalidate"))
        tap(element(app, "memory.invalidate"))
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Invalidar'")).firstMatch
        tap(confirm)
        waitUntil(element(app, "memory.item"), "exists == false")

        let toggle = element(app, "memory.toggleInvalidated")
        waitUntil(toggle, "label CONTAINS 'Mostrar invalidadas (1)'")
        tap(toggle, until: element(app, "memory.item.invalidated"))
        XCTAssertTrue(element(app, "memory.item.invalidated").label.contains("invalidada por el dueño"))
        waitFor(element(app, "memory.purge"))
    }
}
