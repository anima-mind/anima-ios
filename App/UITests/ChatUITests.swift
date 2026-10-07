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

        // Como WhatsApp: separador "Hoy" y la hora al pie de cada mensaje.
        waitUntil(element(app, "chat.dayHeader"), "label == 'Hoy'")
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(identifier: "chat.messageTime").count, 2)

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

    /// Batch 8 #3: el historial queda fijo en el teléfono. Relanzar con sesión
    /// nueva (>8 h) y volver a relanzar (reanuda la sesión nueva VACÍA: la causa
    /// del historial perdido) sigue mostrando lo viejo, con el separador.
    @MainActor
    func testHistorySurvivesNewSessionsAcrossRelaunches() {
        let app = launch()
        onboard(app)
        send(app, "historial fijo")
        waitFor(assistantMessage(app, value: "done", labelContains: fixedReply), timeout: 15)
        app.terminate()

        let fresh = makeApp(reset: false)
        fresh.launchArguments.append("--uitest-fresh-session")
        fresh.launch()
        waitForChat(fresh)
        let old = fresh.staticTexts.matching(identifier: "chat.userMessage")
            .matching(NSPredicate(format: "label == 'historial fijo'")).firstMatch
        waitFor(old)
        waitFor(assistantMessage(fresh, labelContains: fixedReply))
        fresh.terminate()

        let again = launch(reset: false)
        waitForChat(again)
        waitFor(again.staticTexts.matching(identifier: "chat.userMessage")
            .matching(NSPredicate(format: "label == 'historial fijo'")).firstMatch)
        // Un turno nuevo en la sesión nueva: lo viejo arriba, separador de conversación en medio.
        send(again, "seguimos")
        waitFor(assistantMessage(again, value: "done", labelContains: fixedReply), timeout: 15)
        let divider = again.staticTexts.matching(identifier: "chat.sessionDivider")
            .matching(NSPredicate(format: "label == '— nueva conversación —'")).firstMatch
        waitFor(divider)
        let shot = XCTAttachment(screenshot: again.screenshot())
        shot.name = "batch8-03-historial"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Batch 8 #1: la propuesta del deseo se ve UNA vez — la card con
    /// "Hagámoslo / Ahora no" —, también tras relanzar; al aceptarla el dueño ve
    /// "Hagámoslo", no la propuesta repetida.
    @MainActor
    func testProposalShowsOnceAsCard() {
        let app = makeApp()
        app.launchArguments.append("--uitest-seed-intention")
        app.launch()
        onboard(app)
        let proposal = "¿El miércoles a las 8:00 hacemos tu primer check-in?"
        let card = element(app, "chat.proactive.intention")
        waitFor(card)
        waitFor(app.buttons["chat.proactive.accept"])
        waitFor(app.buttons["chat.proactive.dismiss"])
        let copies = app.staticTexts.matching(NSPredicate(format: "label == %@", proposal))
        XCTAssertEqual(copies.count, 1, "la propuesta no se repite como texto suelto")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "batch8-01-propuesta"
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()

        let again = makeApp(reset: false)
        again.launchArguments.append("--uitest-seed-intention")
        again.launch()
        waitForChat(again)
        waitFor(element(again, "chat.proactive.intention"))
        XCTAssertEqual(again.staticTexts.matching(NSPredicate(format: "label == %@", proposal)).count, 1)
        tap(again.buttons["chat.proactive.accept"])
        waitFor(again.staticTexts.matching(identifier: "chat.userMessage")
            .matching(NSPredicate(format: "label == 'Hagámoslo'")).firstMatch)
        waitFor(element(again, "chat.proactive.outcome"))
        XCTAssertEqual(again.staticTexts.matching(NSPredicate(format: "label == %@", proposal)).count, 1)
    }

    /// Batch 8 #2: lo hablado en las gafas aparece en el historial con el chip
    /// "gafas" (glifo eyeglasses), no con el de "voz".
    @MainActor
    func testGlassesTurnShowsGlassesChip() {
        let app = makeApp()
        app.launchArguments.append("--uitest-seed-glasses-turn")
        app.launch()
        onboard(app)
        send(app, "y desde el teléfono")
        waitFor(assistantMessage(app, value: "done", labelContains: fixedReply), timeout: 15)
        app.terminate()

        let again = makeApp(reset: false)
        again.launchArguments.append("--uitest-seed-glasses-turn")
        again.launch()
        waitForChat(again)
        waitFor(again.staticTexts.matching(identifier: "chat.userMessage")
            .matching(NSPredicate(format: "label == '¿qué tengo mañana?'")).firstMatch)
        let chip = element(again, "chat.userMessage.glasses")
        waitFor(chip)
        XCTAssertTrue(again.staticTexts.matching(NSPredicate(format: "label == 'gafas'")).firstMatch.exists)
        XCTAssertFalse(element(again, "chat.userMessage.voice").exists, "un turno de gafas no es 'voz'")
        let shot = XCTAttachment(screenshot: again.screenshot())
        shot.name = "batch8-02-gafas"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Review #34: con un historial largo el chat abre anclado al último mensaje.
    @MainActor
    func testLongHistoryOpensAtTheBottom() {
        let app = makeApp()
        app.launchArguments.append("--uitest-seed-long-history")
        app.launch()
        onboard(app)
        app.terminate()
        let again = makeApp(reset: false)
        again.launchArguments.append("--uitest-seed-long-history")
        again.launch()
        waitForChat(again)
        let last = assistantMessage(again, labelContains: "respuesta 29")
        waitFor(last)
        waitUntil(last, "isHittable == true")
        XCTAssertFalse(assistantMessage(again, labelContains: "respuesta 0").isHittable)
        screenshot(again, "batch8-review-fondo")
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
        // Campo batch 5 #4: la frase del régimen completa, sin "…".
        let sentence = element(app, "mind.regimeSentence")
        waitUntil(sentence, "label == 'Se está formando: todo lo que viven juntos la moldea directo.'")
        XCTAssertGreaterThan(sentence.frame.height, 20, "la frase debe caber en varias líneas")

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
        // Por identifier (no por el texto literal): la barra vive ~1.5 s × escala.
        waitFor(element(app, "chat.listening.label"), timeout: 30)
        waitFor(element(app, "chat.listening.transcript"), timeout: 30)
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

    /// Campo #11 + FIX G: cámara del composer → menú → (picker guionado) → el
    /// adjunto PENDIENTE vive dentro del composer (no en el historial) → enviar →
    /// burbuja con thumb.
    @MainActor
    func testComposerPhotoAttachesAndSends() {
        let app = launch()
        // Con modelo remoto (en Solo-teléfono el menú solo explica que hace falta uno).
        onboard(app, provider: .anthropic(key: "sk-ant-api03-test"))

        tap(app.buttons["chat.camera"])
        tap(app.buttons["Elegir de la galería"])
        let pending = element(app, "chat.attachment.pending")
        waitFor(pending)
        // Dentro del composer, y sin burbuja nueva en el historial hasta enviar.
        let composer = element(app, "chat.composer")
        XCTAssertTrue(composer.descendants(matching: .any)
            .matching(identifier: "chat.attachment.pending").firstMatch.exists)
        XCTAssertFalse(element(app, "chat.userMessage.photo").exists)
        XCTAssertEqual(app.textFields["chat.input"].placeholderValue, "Agrega un mensaje…")
        // Quitar y volver a adjuntar con "Tomar foto".
        tap(app.buttons["nav.close.attachment"])
        waitUntil(pending, "exists == false")
        tap(app.buttons["chat.camera"])
        tap(app.buttons["Tomar foto"])
        waitFor(pending)

        let input = app.textFields["chat.input"]
        tap(input)
        input.typeText("mira esto")
        tap(app.buttons["chat.send"])
        waitFor(element(app, "chat.userMessage.photo"))
        waitUntil(pending, "exists == false")
        waitFor(assistantMessage(app, value: "done", labelContains: fixedReply), timeout: 15)
    }

    /// FIX G: tap al thumb (composer o burbuja) → visor fullscreen → X / swipe-down cierra.
    @MainActor
    func testImageViewerOpensFromThumbsAndCloses() {
        let app = launch()
        onboard(app, provider: .anthropic(key: "sk-ant-api03-test"))

        tap(app.buttons["chat.camera"])
        tap(app.buttons["Elegir de la galería"])
        tap(element(app, "chat.attachment.thumb"))
        let viewer = element(app, "chat.imageViewer")
        waitFor(viewer)
        waitFor(element(app, "chat.imageViewer.image"))
        tap(app.buttons["nav.close.imageViewer"])
        waitUntil(viewer, "exists == false")

        tap(app.buttons["chat.send"])
        let sent = element(app, "chat.userMessage.photo")
        waitFor(sent)
        tap(sent)
        waitFor(viewer)
        let image = element(app, "chat.imageViewer.image")
        waitFor(image)
        image.swipeDown(velocity: .fast)
        waitUntil(viewer, "exists == false")
    }
}

/// Batch 5b #4/#5: el medidor de contexto abre su sheet; "Nueva conversación"
/// agrega su separador (la memoria no se toca). Batch 8 #3: lo visible NO se
/// borra — solo cambia lo que entra al contexto del modelo.
final class ContextUITests: AnimaUITestCase {
    @MainActor
    func testContextMeterOpensSheetAndStartsANewConversation() {
        let app = launch()
        onboard(app)
        send(app, "hola")
        waitFor(assistantMessage(app, value: "done", labelContains: fixedReply), timeout: 15)

        let meter = element(app, "chat.contextMeter")
        waitUntil(meter, "label CONTAINS 'por ciento'")
        tap(meter, until: element(app, "context.sheet"))
        waitFor(element(app, "context.percent"))
        tap(element(app, "context.newConversation"))
        waitUntil(element(app, "context.sheet"), "exists == false")
        waitFor(text(app, "— nueva conversación —"))
        XCTAssertTrue(app.staticTexts.matching(identifier: "chat.userMessage")
            .matching(NSPredicate(format: "label == 'hola'")).firstMatch.exists)
    }
}

/// Batch 5b #7: sin red, pill "Sin conexión" y el turno a Claude se encola.
final class OfflineUITests: AnimaUITestCase {
    @MainActor
    func testOfflinePillAndQueuedTurn() {
        let app = makeApp(reset: true)
        app.launchArguments.append("--uitest-offline")
        app.launch()
        onboard(app, provider: .anthropic(key: "sk-ant-api03-test"))
        let pill = element(app, "chat.offline")
        waitUntil(pill, "label CONTAINS 'Sin conexión'")
        send(app, "hola")
        waitFor(text(app, "Sin conexión: te lo envío apenas vuelva la red."))
        XCTAssertFalse(assistantMessage(app).exists)
    }
}
