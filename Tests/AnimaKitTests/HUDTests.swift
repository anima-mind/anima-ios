import Foundation
import Testing
@testable import AnimaKit

@Suite("HUD — vocabulario cerrado, validador y renderer puro")
struct HUDTests {

    static let card = HUDCard(heading: "Libre de 3:00 a 4:30.", body: "Dos recordatorios vencidos.", overflow: false)

    static let allScreens: [HUDScreen] = [
        .home(status: nil), .home(status: "gafas conectadas"),
        .listening(viaPhone: false), .listening(viaPhone: true),
        .heard(transcript: "¿qué tengo mañana?"),
        .thinking(question: "¿qué tengo mañana?"),
        .speaking(card), .answer(card), .answer(HUDCard(heading: "Listo.", body: "")),
        .declined("No voy a leer sus mensajes. Cuéntame qué te preocupa."),
        .attention("Sin red."),
        .cameraConfirm(reason: "Para ver qué estás mirando."),
        .agentCard(HUDFlexBox(background: .card, children: [.text(HUDText("Hola", style: .heading))])),
        .handoff, .capturing,
    ]

    @Test func catalogoDeIconosEsElDelSDK() {
        #expect(HUDIcon.allCases.count == 116)   // exacto del .swiftinterface 1.0.0 (= 0.9.0; el doc dice "~115")
        #expect(HUDIcon(rawValue: "mic") == nil)
        #expect(HUDIcon(rawValue: "inbox") == nil)
        #expect(HUDIcon(rawValue: "exclamationTriangle") != nil)
    }

    @Test func todaVistaDelRendererPasaElChecklist() throws {
        for screen in Self.allScreens {
            let view = HUDRenderer.render(screen)
            try HUDValidator.validate(view)
            #expect(view.buttons.count <= 3)
            #expect(view.actions.count <= 4)
            if !view.isRoot { #expect(view.actions.contains(.back), "\(view.name) sin Atrás") }
        }
    }

    @Test func homeEsLaCardDeBienvenida() {
        let view = HUDRenderer.render(.home(status: "gafas conectadas · batería 80%"))
        #expect(view.isRoot)
        #expect(view.texts.contains { $0.content == "anima 👋" && $0.style == .heading })
        #expect(view.texts.contains { $0.content == "gafas conectadas · batería 80%" })
        #expect(view.actions == [.talk, .photo])
        #expect(!view.actions.contains(.back))
        guard case .flexBox(let card) = view.root.children.first else { Issue.record("sin card"); return }
        #expect(card.background == .card)
    }

    @Test func textosSoloEnTresEstilosYDosColores() {
        for screen in Self.allScreens {
            for text in HUDRenderer.render(screen).texts {
                #expect(HUDTextStyle.allCases.contains(text.style))
                #expect(text.content.count <= HUDValidator.limit(for: text.style))
            }
        }
    }

    @Test func listeningIndicaFallbackAlTelefono() {
        let phone = HUDRenderer.render(.listening(viaPhone: true))
        #expect(phone.texts.contains { $0.content == "Escuchando por el teléfono" })
        let glasses = HUDRenderer.render(.listening(viaPhone: false))
        #expect(glasses.texts.contains { $0.content.hasPrefix("Escuchando · pausa") })
    }

    // MARK: Validador

    @Test func validadorRechazaVistasFueraDeRegla() {
        let b = { (a: HUDActionID) in HUDNode.button(HUDButton("x", action: a)) }
        let many = HUDView(name: "m", root: HUDFlexBox(children: [b(.back), b(.send), b(.again), b(.reply)]))
        #expect(throws: HUDValidationError.tooManyButtons(4)) { try HUDValidator.validate(many) }

        let taps = HUDView(name: "t", root: HUDFlexBox(children: [
            b(.back),
            .flexBox(HUDFlexBox(onTap: .talk, children: [])),
            .flexBox(HUDFlexBox(onTap: .dismiss, children: [])),
            .flexBox(HUDFlexBox(onTap: .onPhone, children: [])),
            .flexBox(HUDFlexBox(onTap: .reply, children: [])),
        ]))
        #expect(throws: HUDValidationError.tooManyInteractive(5)) { try HUDValidator.validate(taps) }

        let noBack = HUDView(name: "n", root: HUDFlexBox(children: [.text(HUDText("hola"))]))
        #expect(throws: HUDValidationError.missingBack) { try HUDValidator.validate(noBack) }

        let long = HUDView(name: "l", root: HUDFlexBox(children: [.text(HUDText(String(repeating: "a", count: 41), style: .heading))]), isRoot: true)
        #expect(throws: HUDValidationError.textTooLong(style: .heading, count: 41, limit: 40)) { try HUDValidator.validate(long) }

        let empty = HUDView(name: "e", root: HUDFlexBox(children: [.text(HUDText("  "))]), isRoot: true)
        #expect(throws: HUDValidationError.emptyText) { try HUDValidator.validate(empty) }

        let group = HUDView(name: "g", root: HUDFlexBox(children: [.buttonGroup(HUDButtonGroup(buttons: []))]), isRoot: true)
        #expect(throws: HUDValidationError.emptyButtonGroup) { try HUDValidator.validate(group) }

        let img = HUDView(name: "i", root: HUDFlexBox(children: [.image(HUDImage(uri: "http://x.com/a.png"))]), isRoot: true)
        #expect(throws: HUDValidationError.invalidImageURI("http://x.com/a.png")) { try HUDValidator.validate(img) }
        let okImg = HUDView(name: "i", root: HUDFlexBox(children: [.image(HUDImage(uri: "https://x.com/a.png"))]), isRoot: true)
        #expect(HUDValidator.isValid(okImg))

        let label = HUDView(name: "b", root: HUDFlexBox(children: [
            .button(HUDButton(String(repeating: "z", count: 61), action: .back))]))
        #expect(!HUDValidator.isValid(label))
        let blank = HUDView(name: "b", root: HUDFlexBox(children: [.button(HUDButton(" ", action: .back))]))
        #expect(throws: HUDValidationError.emptyText) { try HUDValidator.validate(blank) }

        let spacing = HUDView(name: "s", root: HUDFlexBox(spacing: -1, children: []), isRoot: true)
        #expect(throws: HUDValidationError.invalidNumber("spacing")) { try HUDValidator.validate(spacing) }
        let padding = HUDView(name: "s", root: HUDFlexBox(padding: 100, children: []), isRoot: true)
        #expect(throws: HUDValidationError.invalidNumber("padding")) { try HUDValidator.validate(padding) }

        var deep = HUDFlexBox(children: [])
        for _ in 0..<6 { deep = HUDFlexBox(children: [.flexBox(deep)]) }
        #expect(throws: HUDValidationError.tooDeep(6)) {
            try HUDValidator.validate(HUDView(name: "d", root: deep, isRoot: true))
        }
    }

    @Test func erroresTienenDescripcionLegible() {
        let errors: [HUDValidationError] = [
            .tooManyButtons(4), .tooManyInteractive(5), .missingBack,
            .textTooLong(style: .body, count: 300, limit: 200), .emptyText, .emptyButtonGroup,
            .invalidImageURI("x"), .tooDeep(6), .invalidNumber("spacing"), .unknownComponent("slider"),
            .unknownValue(field: "icon", value: "mic"), .missingField("type"), .notAnObject("tree"), .rootNotFlexBox,
        ]
        for error in errors { #expect(!error.description.isEmpty) }
        #expect(HUDValidationError.unknownComponent("slider").description.contains("slider"))
    }

    // MARK: Parser JSON (input de glasses_show)

    static func json(_ s: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }

    @Test func parserAceptaUnArbolValido() throws {
        let tree = try Self.json("""
        {"type":"flexbox","direction":"column","spacing":10,"padding":12,"background":"card",
         "alignment":"start","cross_alignment":"stretch","children":[
           {"type":"flexbox","direction":"row","spacing":8,"children":[
              {"type":"icon","name":"calendar","style":"outline"},
              {"type":"text","content":"Mañana","style":"meta","color":"secondary"}]},
           {"type":"text","content":"9:00 Standup","style":"heading"},
           {"type":"image","uri":"https://example.com/a.png","size":"fill","corner_radius":"small"},
           {"type":"button","label":"Hablar","style":"outline","icon":"speechBubble","action":"talk"},
           {"type":"button_group","alignment":"end","buttons":[
              {"type":"button","label":"Listo","style":"primary","icon":"checkmark","action":"dismiss"}]}]}
        """)
        let box = try HUDTreeParser.parseRoot(tree)
        #expect(box.background == .card)
        #expect(box.crossAlignment == .stretch)
        #expect(box.padding == 12)
        let view = HUDRenderer.render(.agentCard(box))
        try HUDValidator.validate(view)
        #expect(view.actions.contains(.dismiss))
        #expect(view.actions.contains(.talk))
    }

    @Test func parserRechazaLoQueNoExiste() throws {
        let cases: [(String, HUDValidationError)] = [
            (#"{"type":"slider"}"#, .unknownComponent("slider")),
            (#"{"type":"flexbox","children":[{"type":"icon","name":"mic"}]}"#, .unknownValue(field: "icon", value: "mic")),
            (#"{"type":"flexbox","background":"red"}"#, .unknownValue(field: "background", value: "red")),
            (#"{"type":"flexbox","children":[{"type":"text","content":"a","color":"blue"}]}"#, .unknownValue(field: "color", value: "blue")),
            (#"{"type":"flexbox","children":[{"type":"button","label":"a","action":"delete_all"}]}"#, .unknownValue(field: "action", value: "delete_all")),
            (#"{"type":"flexbox","children":[{"type":"button","label":"a"}]}"#, .missingField("action")),
            (#"{"type":"flexbox","children":[{"type":"button","action":"dismiss"}]}"#, .missingField("label")),
            (#"{"type":"flexbox","children":[{"type":"button","label":"a","icon":"inbox","action":"dismiss"}]}"#, .unknownValue(field: "icon", value: "inbox")),
            (#"{"type":"flexbox","children":[{"type":"text"}]}"#, .missingField("content")),
            (#"{"type":"flexbox","children":[{"type":"icon"}]}"#, .missingField("name")),
            (#"{"type":"flexbox","children":[{"type":"image"}]}"#, .missingField("uri")),
            (#"{"type":"flexbox","children":[{"type":"button_group"}]}"#, .missingField("buttons")),
            (#"{"type":"flexbox","children":[{"type":"button_group","buttons":[{"type":"text","content":"a"}]}]}"#, .unknownComponent("text")),
            (#"{"type":"flexbox","children":[{"type":"button_group","buttons":[3]}]}"#, .notAnObject("button")),
            (#"{"type":"flexbox","children":{"a":1}}"#, .notAnObject("children")),
            (#"{"type":"flexbox","children":[3]}"#, .notAnObject("nodo")),
            (#"{"children":[]}"#, .missingField("type")),
            (#"{"type":"flexbox","spacing":"mucho"}"#, .invalidNumber("spacing")),
            (#"{"type":"flexbox","direction":3}"#, .unknownValue(field: "direction", value: "int(3)")),
            (#"{"type":"text","content":"a"}"#, .rootNotFlexBox),
            (#"[1]"#, .notAnObject("tree")),
        ]
        for (raw, expected) in cases {
            #expect(throws: expected, "\(raw)") { try HUDTreeParser.parseRoot(try Self.json(raw)) }
        }
        var nested = #"{"type":"flexbox"}"#
        for _ in 0..<6 { nested = #"{"type":"flexbox","children":["# + nested + "]}" }
        #expect(throws: HUDValidationError.tooDeep(6)) { try HUDTreeParser.parseRoot(try Self.json(nested)) }
        let doubles = try HUDTreeParser.parseRoot(try Self.json(#"{"type":"flexbox","spacing":2.5,"padding":null}"#))
        #expect(doubles.spacing == 2.5)
        #expect(doubles.padding == nil)
    }

    // MARK: Resumen (gist + TTS)

    @Test func resumenCortaAlPresupuesto() {
        let short = HUDSummary.card(from: "**Libre** de 3:00 a 4:30. Tienes dos recordatorios vencidos.")
        #expect(short.heading == "Libre de 3:00 a 4:30.")
        #expect(short.body == "Tienes dos recordatorios vencidos.")
        #expect(!short.overflow)

        let longHeading = HUDSummary.card(from: "Mañana tienes una agenda bastante cargada desde temprano hasta tarde")
        #expect(longHeading.heading.count <= 40)
        #expect(longHeading.heading.hasSuffix("…"))
        #expect(longHeading.body.hasPrefix("Mañana tienes"))

        let essay = "Hola. " + String(repeating: "Esto es una frase larga de relleno. ", count: 20)
        let big = HUDSummary.card(from: essay)
        #expect(big.overflow)
        #expect(big.body.count <= 200)

        let empty = HUDSummary.card(from: "  ")
        #expect(empty.heading == "Listo.")
    }

    @Test func plainQuitaMarkdown() {
        let text = HUDSummary.plain("# Agenda\n- **9:00** standup\n* `café`\n• fin\n__ok__")
        #expect(text == "Agenda 9:00 standup café fin ok")
        #expect(HUDSummary.sentences("Uno. ¿Dos? Tres! cola") == ["Uno.", "¿Dos?", "Tres!", "cola"])
        #expect(HUDSummary.clip("corto", 10) == "corto")
        #expect(HUDSummary.clip("palabra larguísima aquí", 12) == "palabra…")
    }

    @Test func ttsCortoRemiteAlTelefono() {
        #expect(HUDSummary.spoken(from: "Libre a las 3.") == "Libre a las 3.")
        let long = String(repeating: "Frase de relleno bastante larga. ", count: 20)
        let spoken = HUDSummary.spoken(from: long)
        #expect(spoken.hasSuffix(HUDSummary.phoneTail))
        #expect(spoken.count <= HUDSummary.spokenLimit + HUDSummary.phoneTail.count + 1)
        let oneHuge = String(repeating: "palabra ", count: 80)
        #expect(HUDSummary.spoken(from: oneHuge).hasSuffix(HUDSummary.phoneTail))
    }
}

@Suite("HUD — máquina de estados (handoff)")
struct HUDStateMachineTests {
    typealias S = HUDConversationState

    func step(_ s: S, _ e: HUDEvent) -> (S, [HUDEffect]) {
        let r = HUDStateMachine.reduce(s, e)
        return (r.state, r.effects)
    }

    @Test func conversacionCompletaManosLibres() {
        var s = S(status: "gafas conectadas")
        var fx: [HUDEffect]
        (s, fx) = step(s, .action(.talk))
        #expect(s.screen == .listening(viaPhone: false)); #expect(fx == [.startListening])
        (s, fx) = step(s, .listeningRoute(viaPhone: true))
        #expect(s.screen == .listening(viaPhone: true)); #expect(fx.isEmpty)
        (s, fx) = step(s, .transcript("¿qué tengo mañana?"))
        #expect(s.screen == .heard(transcript: "¿qué tengo mañana?"))
        (s, fx) = step(s, .action(.send))
        #expect(s.screen == .thinking(question: "¿qué tengo mañana?")); #expect(fx == [.submit("¿qué tengo mañana?")])
        (s, fx) = step(s, .turnFinished(reply: "Mañana: standup a las 9. Almuerzo con Ana."))
        guard case .speaking(let card) = s.screen else { Issue.record("no speaking"); return }
        #expect(card.heading == "Mañana: standup a las 9.")
        #expect(fx == [.speak("Mañana: standup a las 9. Almuerzo con Ana.")])
        (s, fx) = step(s, .speechFinished)
        #expect(s.screen == .answer(card))
        (s, fx) = step(s, .action(.reply))
        #expect(s.screen == .listening(viaPhone: false)); #expect(fx == [.startListening])
        (s, fx) = step(s, .action(.cancel))
        #expect(s.screen == .home(status: "gafas conectadas")); #expect(fx == [.stopListening])
    }

    @Test func caminosSecundarios() {
        let home = HUDScreen.home(status: nil)
        #expect(step(S(screen: .listening(viaPhone: false)), .transcript(nil)).0.screen == home)
        #expect(step(S(screen: .listening(viaPhone: false)), .action(.back)).1 == [.stopListening])
        #expect(step(S(screen: .heard(transcript: "x")), .action(.again)).1 == [.startListening])
        #expect(step(S(screen: .heard(transcript: "x")), .action(.back)).0.screen == home)
        #expect(step(S(screen: .thinking(question: "x")), .action(.cancel)).1 == [.cancelTurn])
        #expect(step(S(screen: .thinking(question: "x")), .turnRefused("No.")).0.screen == .declined("No."))
        #expect(step(S(screen: .thinking(question: "x")), .turnFailed("red")).0.screen == .attention("red"))
        let empty = step(S(screen: .thinking(question: "x")), .turnFinished(reply: ""))
        #expect(empty.1.isEmpty)
        if case .answer = empty.0.screen {} else { Issue.record("respuesta vacía debe ir a answer") }

        let card = HUDCard(heading: "h", body: "b")
        #expect(step(S(screen: .speaking(card)), .action(.reply)).1 == [.stopSpeaking, .startListening])
        #expect(step(S(screen: .speaking(card)), .action(.onPhone)).1 == [.stopSpeaking, .openPhone])
        #expect(step(S(screen: .speaking(card)), .action(.back)).1 == [.stopSpeaking])
        #expect(step(S(screen: .answer(card)), .action(.onPhone)).0.screen == .handoff)
        #expect(step(S(screen: .handoff), .action(.back)).0.screen == home)
        #expect(step(S(screen: .answer(card)), .action(.back)).0.screen == home)
        #expect(step(S(screen: .declined("x")), .action(.back)).0.screen == home)
        #expect(step(S(screen: .attention("x")), .action(.back)).0.screen == home)
        // Evento sin transición: sin cambios.
        #expect(step(S(), .action(.send)).0 == S())
        #expect(step(S(), .speechFinished).1.isEmpty)
    }

    @Test func camaraSuspendeYRetomaElTurno() {
        let thinking = S(screen: .thinking(question: "¿qué veo?"))
        var (s, fx) = step(thinking, .cameraRequested(reason: "ver qué miras"))
        #expect(s.screen == .cameraConfirm(reason: "ver qué miras")); #expect(fx.isEmpty)
        (s, fx) = step(s, .cameraRequested(reason: "otra"))
        #expect(fx == [.resolveCamera(false)])   // una a la vez: la segunda se niega
        (s, fx) = step(s, .action(.cameraAllow))
        #expect(s.screen == .thinking(question: "¿qué veo?")); #expect(fx == [.resolveCamera(true)])

        (s, fx) = step(thinking, .cameraRequested(reason: "r"))
        (s, fx) = step(s, .action(.back))
        #expect(fx == [.resolveCamera(false)])
        #expect(s.screen == .thinking(question: "¿qué veo?"))

        (s, fx) = step(S(screen: .listening(viaPhone: false)), .cameraRequested(reason: "r"))
        #expect(fx == [.stopListening])
        (s, fx) = step(s, .action(.cameraDeny))
        #expect(s.screen == .home(status: nil)); #expect(fx == [.resolveCamera(false)])
    }

    @Test func salidaDeSesionLimpia() {
        let card = HUDCard(heading: "h", body: "b")
        #expect(step(S(screen: .listening(viaPhone: false)), .exited).1 == [.stopListening])
        #expect(step(S(screen: .speaking(card)), .exited).1 == [.stopSpeaking])
        #expect(step(S(screen: .cameraConfirm(reason: "r")), .exited).1 == [.resolveCamera(false)])
        let out = step(S(screen: .answer(card), status: "ok"), .exited)
        #expect(out.0.screen == .home(status: "ok")); #expect(out.1.isEmpty)
    }

    @Test func cardDelAgente() {
        let box = HUDFlexBox(background: .card, children: [.text(HUDText("Hola"))])
        var (s, fx) = step(S(screen: .thinking(question: "q")), .agentCard(box))
        #expect(s.screen == .agentCard(box))
        (s, fx) = step(s, .turnFinished(reply: "Te lo mostré."))
        #expect(s.screen == .agentCard(box)); #expect(fx == [.speak("Te lo mostré.")])
        #expect(step(s, .turnFinished(reply: "")).1.isEmpty)
        #expect(step(s, .action(.dismiss)).0.screen == .home(status: nil))
        #expect(step(s, .action(.onPhone)).1 == [.openPhone])
        #expect(step(s, .action(.talk)).1 == [.startListening])
        // No interrumpe captura ni confirmación.
        #expect(step(S(screen: .listening(viaPhone: false)), .agentCard(box)).0.screen == .listening(viaPhone: false))
        #expect(step(S(screen: .heard(transcript: "t")), .agentCard(box)).0.screen == .heard(transcript: "t"))
        #expect(step(S(screen: .cameraConfirm(reason: "r")), .agentCard(box)).0.screen == .cameraConfirm(reason: "r"))
    }
}
