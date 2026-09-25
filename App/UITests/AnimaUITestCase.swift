// AnimaUITestCase.swift — base de la suite XCUITest: lanzamiento en modo
// `--uitest` (dobles deterministas, ver App/UITestSupport.swift) y los pasos
// del onboarding como helpers. Solo waits explícitos: nada de sleeps ciegos.

import XCTest

/// Respuesta fija del provider guionado del shell (UITestScriptedProvider.fixedReply).
let fixedReply = "Hola, soy Anima en modo de prueba. Te escucho."

class AnimaUITestCase: XCTestCase {
    /// Timeout por defecto de cada espera explícita.
    let timeout: TimeInterval = 15

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: Lanzamiento

    @MainActor
    func makeApp(reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"] + (reset ? ["--uitest-reset"] : [])
        return app
    }

    @MainActor
    @discardableResult
    func launch(reset: Bool = true) -> XCUIApplication {
        let app = makeApp(reset: reset)
        app.launch()
        return app
    }

    // MARK: Esperas

    @MainActor
    @discardableResult
    func waitFor(_ element: XCUIElement, timeout: TimeInterval? = nil,
                 file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if element.exists { return element }
        XCTAssertTrue(element.waitForExistence(timeout: timeout ?? self.timeout),
                      "No apareció: \(element)", file: file, line: line)
        return element
    }

    @MainActor
    func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        waitFor(element, file: file, line: line)
        waitUntil(element, "isHittable == true", file: file, line: line)
        element.tap()
    }

    /// Tap con verificación: un tap durante una transición (fade de paso, inercia
    /// de scroll) se pierde en SwiftUI; se reintenta acotado hasta ver el efecto.
    @MainActor
    func tap(_ element: XCUIElement, until effect: XCUIElement, _ format: String = "exists == true",
             attempts: Int = 3, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: format)
        for _ in 0..<attempts {
            tap(element, file: file, line: line)
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: effect)
            if XCTWaiter().wait(for: [expectation], timeout: 3) == .completed { return }
        }
        XCTFail("Sin efecto tras \(attempts) taps en \(element): '\(format)' en \(effect)", file: file, line: line)
    }

    /// Espera a que un predicado sobre el elemento se cumpla (sin sleeps).
    @MainActor
    func waitUntil(_ element: XCUIElement, _ format: String, timeout: TimeInterval? = nil,
                   file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: format)
        // Camino rápido: si ya se cumple, no se paga el polling de 1 s del waiter.
        if element.exists, predicate.evaluate(with: element) { return }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout ?? self.timeout)
        XCTAssertEqual(result, .completed, "No se cumplió '\(format)' en \(element)", file: file, line: line)
    }

    @MainActor
    func text(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.staticTexts[label]
    }

    /// Cualquier elemento por identifier (tipo exacto varía con SwiftUI).
    @MainActor
    func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Hace scroll hasta que el elemento sea tocable.
    @MainActor
    func scrollTo(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 6) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
    }

    // MARK: Tabs

    @MainActor
    func openTab(_ app: XCUIApplication, _ label: String) {
        let button = app.tabBars.buttons[label]
        tap(button)
    }

    // MARK: Onboarding

    enum ProviderChoice {
        case onDevice
        case anthropic(key: String)
    }

    @MainActor
    func startFromLanding(_ app: XCUIApplication) {
        waitFor(text(app, "Una mente que vive en tu teléfono y crece contigo."))
        tap(app.buttons["landing.begin"])
    }

    @MainActor
    func passTutorialAndAccount(_ app: XCUIApplication) {
        waitFor(text(app, "Qué es Anima"))
        tap(app.buttons["onboarding.next"])
        waitFor(text(app, "Tu cuenta"))
        tap(app.buttons["onboarding.account.skip"])
    }

    @MainActor
    func chooseProvider(_ app: XCUIApplication, _ choice: ProviderChoice) {
        waitFor(text(app, "El modelo detrás de la mente"))
        switch choice {
        case .onDevice:
            let option = app.buttons["onboarding.provider.on_device"]
            tap(option, until: option, "isSelected == true")
            tap(app.buttons["onboarding.next"])
        case .anthropic(let key):
            let option = app.buttons["onboarding.provider.anthropic"]
            tap(option, until: option, "isSelected == true")
            tap(app.buttons["onboarding.next"])
            waitFor(text(app, "Tu API key"))
            let field = app.textFields["onboarding.apiKey.field"]
            tap(field)
            field.typeText(key + "\n")
            let status = app.staticTexts["onboarding.apiKey.status"]
            waitUntil(status, "label BEGINSWITH 'Sin red: formato ok'")
            let next = app.buttons["onboarding.next"]
            waitUntil(next, "isEnabled == true")
            tap(next)
        }
    }

    @MainActor
    func passPermissionsAndGlasses(_ app: XCUIApplication) {
        waitFor(text(app, "Su cuerpo, con tu permiso"))
        tap(app.buttons["onboarding.next"])   // sin conceder nada
        waitFor(text(app, "Un cuerpo en tu cara"))
        let notNow = app.buttons["onboarding.next"]
        XCTAssertEqual(notNow.label, "Ahora no")
        tap(notNow)
    }

    /// Birth conversacional: chip, chip, texto libre → summary card → Comenzar.
    @MainActor
    func completeBirth(_ app: XCUIApplication) {
        waitFor(text(app, "Nacimiento"))
        tap(app.buttons["birth.chip.Anima"])
        tap(app.buttons["birth.chip.Cálido y tranquilo"])
        waitFor(app.buttons["birth.chip.Actúa y me cuentas"])
        let input = app.textFields["birth.input"]
        tap(input)
        input.typeText("Pregunta siempre")
        tap(app.buttons["birth.send"])

        let summary = element(app, "birth.summary")
        waitFor(summary)
        XCTAssertTrue(summary.staticTexts["ASÍ NAZCO"].exists)
        XCTAssertTrue(summary.staticTexts["Anima"].exists)
        XCTAssertTrue(summary.staticTexts["Cálido y tranquilo"].exists)
        XCTAssertTrue(summary.staticTexts["Pregunta siempre"].exists)
        tap(app.buttons["birth.begin"])
    }

    /// Onboarding completo hasta aterrizar en Chat.
    @MainActor
    func onboard(_ app: XCUIApplication, provider: ProviderChoice = .onDevice) {
        startFromLanding(app)
        passTutorialAndAccount(app)
        chooseProvider(app, provider)
        passPermissionsAndGlasses(app)
        completeBirth(app)
        waitForChat(app)
    }

    @MainActor
    func waitForChat(_ app: XCUIApplication) {
        waitFor(app.textFields["chat.input"], timeout: 20)
        XCTAssertTrue(app.tabBars.firstMatch.exists)
    }

    // MARK: Chat

    @MainActor
    func send(_ app: XCUIApplication, _ message: String) {
        let input = app.textFields["chat.input"]
        tap(input)
        input.typeText(message)
        tap(app.buttons["chat.send"])
    }

    /// El último mensaje del agente (identifier estable, value streaming|done).
    @MainActor
    func assistantMessage(_ app: XCUIApplication, value: String? = nil, labelContains: String? = nil) -> XCUIElement {
        var formats: [String] = []
        var args: [Any] = []
        if let value { formats.append("value == %@"); args.append(value) }
        if let labelContains { formats.append("label CONTAINS %@"); args.append(labelContains) }
        let query = app.descendants(matching: .any).matching(identifier: "chat.assistantMessage")
        guard !formats.isEmpty else { return query.firstMatch }
        return query.matching(NSPredicate(format: formats.joined(separator: " AND "), argumentArray: args)).firstMatch
    }
}
