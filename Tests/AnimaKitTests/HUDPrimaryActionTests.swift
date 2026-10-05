import Foundation
import Testing
@testable import AnimaKit

@Suite("HUD — foco en el botón primario (DAT 1.0 Button.actionRole(.primary))")
struct HUDPrimaryActionTests {

    static func primary(_ screen: HUDScreen) -> [HUDActionID] {
        HUDRenderer.render(screen).buttons.filter(\.isPrimaryAction).map(\.action)
    }

    static let card = HUDCard(heading: "Libre a las 3.", body: "", overflow: false)

    @Test func elFocoCaeDondeAhorraPinches() {
        #expect(Self.primary(.heard(transcript: "¿qué tengo hoy?")) == [.send])
        #expect(Self.primary(.answer(Self.card)) == [.reply])
        #expect(Self.primary(.speaking(Self.card)) == [.reply])
        #expect(Self.primary(.cameraConfirm(reason: "Para ver qué miras.")) == [.cameraAllow])
        #expect(Self.primary(.handoff) == [.back])
    }

    @Test func pantallasSinFocoDeclarado() {
        for screen: HUDScreen in [.home(status: nil), .listening(viaPhone: false), .thinking(question: "x"),
                                  .capturing, .declined("No."), .attention("Sin red.")] {
            #expect(Self.primary(screen).isEmpty, "\(screen)")
        }
    }

    @Test func pordefectoNoEsPrimario() {
        #expect(HUDButton("Ok", action: .dismiss).isPrimaryAction == false)
    }

    @Test func validadorRechazaDosPrimarios() {
        let view = HUDView(name: "x", root: HUDFlexBox(children: [
            .buttonGroup(HUDButtonGroup(buttons: [
                HUDButton("A", action: .dismiss, isPrimaryAction: true),
                HUDButton("B", action: .talk, isPrimaryAction: true),
            ])),
        ]), isRoot: true)
        #expect(throws: HUDValidationError.multiplePrimaryActions(2)) { try HUDValidator.validate(view) }
        #expect(HUDValidator.isValid(view) == false)
        // Suelto + en grupo cuenta igual.
        let mixed = HUDView(name: "y", root: HUDFlexBox(children: [
            .button(HUDButton("Atrás", style: .outline, action: .back, isPrimaryAction: true)),
            .buttonGroup(HUDButtonGroup(buttons: [HUDButton("B", action: .talk, isPrimaryAction: true)])),
        ]))
        #expect(throws: HUDValidationError.multiplePrimaryActions(2)) { try HUDValidator.validate(mixed) }
        #expect(HUDValidationError.multiplePrimaryActions(2).description.contains("máximo 1"))
    }

    static func json(_ s: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }

    @Test func parserLeePrimaryAction() throws {
        let box = try HUDTreeParser.parseRoot(try Self.json("""
        {"type":"flexbox","children":[{"type":"button_group","buttons":[
          {"type":"button","label":"Listo","action":"dismiss","primary_action":true},
          {"type":"button","label":"Hablar","action":"talk","primary_action":false,"style":"outline"},
          {"type":"button","label":"Tel","action":"on_phone","primary_action":null}]}]}
        """))
        let view = HUDView(name: "agent", root: box, isRoot: true)
        try HUDValidator.validate(view)
        #expect(view.buttons.filter(\.isPrimaryAction).map(\.action) == [.dismiss])
    }

    @Test func parserRechazaPrimaryActionNoBooleano() throws {
        let bad = try Self.json("""
        {"type":"flexbox","children":[{"type":"button","label":"Listo","action":"dismiss","primary_action":"sí"}]}
        """)
        #expect(throws: HUDValidationError.self) { try HUDTreeParser.parseRoot(bad) }
    }

    @Test func agenteConDosPrimariosNoPasa() throws {
        let box = try HUDTreeParser.parseRoot(try Self.json("""
        {"type":"flexbox","children":[{"type":"button_group","buttons":[
          {"type":"button","label":"A","action":"dismiss","primary_action":true},
          {"type":"button","label":"B","action":"talk","primary_action":true}]}]}
        """))
        #expect(throws: HUDValidationError.multiplePrimaryActions(2)) {
            try HUDValidator.validate(HUDRenderer.render(.agentCard(box)))
        }
    }
}
