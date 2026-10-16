// MemoryUITests.swift — Memoria legible (batch 5b #10): origen "Noche #1 ·
// destilado"; "Invalidar recuerdo" (botón real, razón opcional) la pasa a
// ocultas; "Mostrar invalidadas" las despliega. Campo 2026-10-16: una
// invalidada se restaura (o se restaura esa versión) o se elimina sola.

import XCTest

final class MemoryUITests: AnimaUITestCase {
    static let replacedReason = "reemplazada por el dueño"

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
        // Batch 8 #4: la X del detalle dentro del padding, en la fila del título.
        assertSheetClose(app, "memoryDetail")
        screenshot(app, "batch8-04-memory")
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

    // MARK: Restaurar y eliminar (campo 2026-10-16)

    @MainActor
    private func memoryRow(_ app: XCUIApplication, _ identifier: String, _ content: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", identifier, content)).firstMatch
    }

    @MainActor
    private func confirmButton(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "label == %@ AND NOT (identifier BEGINSWITH 'memory.')", label)).firstMatch
    }

    /// iOS 26 presenta el diálogo como popover sin botón Cancelar: se cierra tocando fuera.
    @MainActor
    private func cancelDialog(_ app: XCUIApplication) {
        let title = app.staticTexts["¿Eliminar este recuerdo para siempre?"]
        waitFor(title)
        let cancel = confirmButton(app, "Cancelar")
        if cancel.exists && cancel.isHittable {
            cancel.tap()
        } else if app.otherElements["PopoverDismissRegion"].exists {
            app.otherElements["PopoverDismissRegion"].firstMatch.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        }
        waitUntil(title, "exists == false")
    }

    @MainActor
    private func showInvalidated(_ app: XCUIApplication, count: Int) {
        let toggle = element(app, "memory.toggleInvalidated")
        waitUntil(toggle, "label CONTAINS 'Mostrar invalidadas (\(count))'")
        tap(toggle, until: element(app, "memory.item.invalidated"))
    }

    @MainActor
    func testInvalidateThenRestoreFromTheSheetMakesItCurrent() {
        let app = makeApp(reset: true)
        app.launchArguments.append("--uitest-seed-memory")
        app.launch()
        onboard(app)
        openTab(app, "Memoria")

        let seeded = "Le gusta correr temprano"
        tap(memoryRow(app, "memory.item", seeded), until: element(app, "memory.invalidate"))
        // Control negativo: una vigente no ofrece restaurar ni eliminar.
        XCTAssertFalse(element(app, "memory.restore").exists)
        XCTAssertFalse(element(app, "memory.delete").exists)
        screenshot(app, "memory-sheet-vigente")
        tap(element(app, "memory.invalidate"))
        tap(confirmButton(app, "Invalidar"))
        waitUntil(memoryRow(app, "memory.item", seeded), "exists == false")

        showInvalidated(app, count: 1)
        tap(memoryRow(app, "memory.item.invalidated", seeded), until: element(app, "memory.restore"))
        XCTAssertFalse(element(app, "memory.invalidate").exists)
        waitFor(element(app, "memory.delete"))
        XCTAssertTrue(element(app, "memory.restore").label.contains("Restaurar"))
        screenshot(app, "memory-sheet-invalidada")
        tap(element(app, "memory.restore"), until: element(app, "memory.invalidate"))
        let event = element(app, "memory.history.event")
        waitFor(event)
        XCTAssertTrue(event.label.hasPrefix("restaurada por el dueño · "), event.label)
        screenshot(app, "memory-sheet-restaurada")
        tap(app.buttons["nav.close.memoryDetail"])

        waitFor(memoryRow(app, "memory.item", seeded))
        waitUntil(element(app, "memory.toggleInvalidated"), "exists == false")
        XCTAssertFalse(memoryRow(app, "memory.item.invalidated", seeded).exists)
    }

    @MainActor
    func testRestoreThisVersionLeavesOnlyOneCurrentInTheChain() {
        let app = makeApp(reset: true)
        app.launchArguments += ["--uitest-seed-memory", "--uitest-seed-memory-chain"]
        app.launch()
        onboard(app)
        openTab(app, "Memoria")

        let old = "Corre los martes", new = "Corre los martes y los jueves"
        waitFor(memoryRow(app, "memory.item", new))
        showInvalidated(app, count: 1)
        tap(memoryRow(app, "memory.item.invalidated", old), until: element(app, "memory.restore"))
        waitUntil(element(app, "memory.restore"), "label CONTAINS 'Restaurar esta versión'")
        waitFor(element(app, "memory.history.current"))
        screenshot(app, "memory-sheet-reemplazada")
        tap(element(app, "memory.restore"), until: element(app, "memory.invalidate"))

        let replaced = element(app, "memory.history.invalidated")
        waitFor(replaced)
        waitFor(replaced.staticTexts[new])
        waitFor(replaced.staticTexts["invalidada: \(Self.replacedReason)"])
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "memory.history.current").count, 1)
        screenshot(app, "memory-sheet-version-restaurada")
        tap(app.buttons["nav.close.memoryDetail"])

        waitFor(memoryRow(app, "memory.item", old))
        XCTAssertFalse(memoryRow(app, "memory.item", new).exists)
        waitFor(memoryRow(app, "memory.item.invalidated", new))
    }

    @MainActor
    func testDeleteOnlyThatInvalidatedKeepsTheOthers() {
        let app = makeApp(reset: true)
        app.launchArguments += ["--uitest-seed-memory", "--uitest-seed-memory-chain"]
        app.launch()
        onboard(app)
        openTab(app, "Memoria")

        let seeded = "Le gusta correr temprano", old = "Corre los martes"
        tap(memoryRow(app, "memory.item", seeded), until: element(app, "memory.invalidate"))
        tap(element(app, "memory.invalidate"))
        tap(confirmButton(app, "Invalidar"))
        waitUntil(memoryRow(app, "memory.item", seeded), "exists == false")

        showInvalidated(app, count: 2)
        tap(memoryRow(app, "memory.item.invalidated", seeded), until: element(app, "memory.delete"))
        tap(element(app, "memory.delete"))
        // Control negativo: cancelar no borra nada.
        cancelDialog(app)
        waitFor(element(app, "memory.delete"))
        tap(element(app, "memory.delete"))
        waitFor(app.staticTexts["¿Eliminar este recuerdo para siempre?"])
        tap(confirmButton(app, "Eliminar"))
        waitUntil(element(app, "memory.delete"), "exists == false")

        waitUntil(memoryRow(app, "memory.item.invalidated", seeded), "exists == false")
        waitFor(memoryRow(app, "memory.item.invalidated", old))
        waitFor(memoryRow(app, "memory.item", "Corre los martes y los jueves"))

        // Swipe en la lista: Eliminar pide confirmación; Cancelar la deja.
        let row = memoryRow(app, "memory.item.invalidated", old)
        row.swipeLeft()
        let swipeDelete = app.buttons["Eliminar"].firstMatch
        tap(swipeDelete)
        cancelDialog(app)
        waitFor(memoryRow(app, "memory.item.invalidated", old))
    }
}
