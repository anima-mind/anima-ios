import Foundation
import GRDB
import Testing
@testable import AnimaKit

// "ya no quiero ahorrar, mejor abonar a la deuda" (campo 2026-10-15): la
// lectura determinista del texto del dueño y la tool local `drop_goal`.

@Suite struct GoalDropParseTests {
    @Test(arguments: [
        ("ya no quiero ahorrar, mejor quiero abonar a la deuda 5M cada quincena", "ahorrar",
         "abonar a la deuda 5M cada quincena"),
        ("Ya no quiero ahorrar, mejor quiero abonar 5M a la deuda", "ahorrar", "abonar 5M a la deuda"),
        ("ya no quiero ahorrar", "ahorrar", nil),
        ("olvida la meta de correr 10 km", "correr 10 km", nil),
        ("cancela mi meta de leer 12 libros", "leer 12 libros", nil),
        ("quiero abonar a la deuda en vez de ahorrar", "ahorrar", "abonar a la deuda"),
        ("en vez de ahorrar, mejor quiero abonar a la deuda", "ahorrar", "abonar a la deuda"),
        ("la meta de leer ya no me interesa", "leer", nil),
        ("ya no quiero bajar de peso, ahora quiero ganar músculo", "bajar de peso", "ganar músculo"),
    ] as [(String, String, String?)])
    func dropsAGoal(text: String, old: String, new: String?) throws {
        let parsed = try #require(GoalDrop.parse(text))
        #expect(parsed.old == old)
        #expect(parsed.new == new)
    }

    @Test(arguments: ["ya no quiero que me recuerdes lo del banco", "deja de recordarme tomar agua",
                      "elimina la cita de la agenda", "quiero ahorrar 30 millones", "hola", "ya cumplí mi meta de leer",
                      "quiero cambiar mi meta", "borra la nota de compras"])
    func doesNotDropAGoal(text: String) {
        #expect(GoalDrop.parse(text) == nil)
    }

    @Test func cueIsRequiredForTheSleep() {
        #expect(GoalDrop.hasCue("ya no quiero ahorrar"))
        #expect(GoalDrop.hasCue("mejor abono a la deuda"))
        #expect(!GoalDrop.hasCue("me encanta ahorrar, voy bien"))
    }

    @Test func overlapAndRelated() {
        #expect(GoalDedupe.overlap("ahorrar", "Ahorrar 30 millones de pesos para diciembre de 2026") == 1)
        #expect(GoalDedupe.overlap("abonar a la deuda", "Ahorrar 30 millones") == 0)
        #expect(GoalDedupe.related("Ahorrar 30 millones para diciembre", "Ahorrar 30 millones de pesos para diciembre de 2026"))
        #expect(!GoalDedupe.related("Ahorrar para un carro", "Ahorrar 30 millones de pesos para diciembre de 2026"))
    }
}

@Suite struct LocalDropGoalTests {
    static let now = Date(timeIntervalSince1970: 1_791_228_600)

    static func resolve(_ name: String, _ input: [String: JSONValue], owner: String) -> LocalToolAdapter.Resolution {
        LocalToolAdapter.resolve(name: name, input: .object(input), now: now, ownerText: owner)
    }

    @Test func theLocalVerb() {
        #expect(LocalToolAdapter.verb(local: "drop_goal") == "dejar la meta")
    }

    @Test func theOwnersWordsDriveTheReplacement() {
        let r = Self.resolve("drop_goal", ["goal": .string("correr")],
                             owner: "ya no quiero ahorrar, mejor quiero abonar a la deuda 5M cada quincena")
        #expect(r == .real(name: "goals", input: .object([
            "action": .string("replace"), "goal": .string("ahorrar"),
            "statement": .string("Abonar a la deuda 5M cada quincena"),
        ])))
    }

    @Test func dropWithoutReplacementAndWithoutOwnerText() {
        #expect(Self.resolve("drop_goal", [:], owner: "olvida mi meta de correr")
                == .real(name: "goals", input: .object(["action": .string("abandon"), "goal": .string("correr")])))
        #expect(Self.resolve("drop_goal", ["goal": .string("correr")], owner: "")
                == .real(name: "goals", input: .object(["action": .string("abandon"), "goal": .string("correr")])))
        // El 3B copia el ejemplo ("correr") cuando el dueño no nombró nada: no se inventa la meta.
        guard case .invalid(let tool, let message) = Self.resolve("drop_goal", ["goal": .string("correr")], owner: "hola")
        else { Issue.record("esperaba invalid"); return }
        #expect(tool == "goals" && message.contains("`goal`"))
        #expect(Self.resolve("drop_goal", ["goal": .string("none")], owner: "")
                != .real(name: "goals", input: .object(["action": .string("abandon"), "goal": .string("none")])))
    }

    @Test func aDeclareWhileDroppingIsAReplacementWithTheOwnersCadence() {
        let r = Self.resolve("declare_goal", ["statement": .string("nadar"), "checkin": .string("weekly"), "hour": .int(9)],
                             owner: "ya no quiero correr, mejor quiero nadar cada semana a las 7 pm")
        guard case .real(let name, let input) = r else { Issue.record("\(r)"); return }
        #expect(name == "goals")
        #expect(input["action"] == .string("replace") && input["goal"] == .string("correr"))
        #expect(input["statement"]?.stringValue?.hasPrefix("Nadar") == true)
        #expect(input["checkin"]?["cadence"] == .string("weekly") && input["checkin"]?["hour"] == .int(19))
        // Sin la nueva en el texto del dueño: la del modelo si nombra algo que dijo.
        let model = Self.resolve("declare_goal", ["statement": .string("abonar a la deuda")],
                                 owner: "ya no quiero ahorrar, quiero abonar a la deuda")
        guard case .real(_, let input2) = model else { Issue.record("\(model)"); return }
        #expect(input2["goal"] == .string("ahorrar"))
    }

    @Test func theDropConfirmationIsWhatWasSaved() throws {
        let saved = "Listo: dejé la meta «Correr» (id G-1); ya no te la recuerdo. Cancelé su seguimiento (cada día a las 20:00)."
        let ctx = AssembledContext(messages: [
            .user("olvida mi meta de correr"),
            .assistant([.toolUse(id: "t1", name: "drop_goal", input: .object(["goal": .string("correr")]))]),
            .user([.toolResult(toolUseId: "t1", content: saved, isError: false)]),
        ])
        let request = OnDevicePromptBuilder.request(ctx: ctx, tools: [], opts: try OnDeviceTestConfig.opts())
        #expect(request.listIsDeterministic)
        #expect(request.fallbackText == "Listo, dejé la meta «Correr»; ya no te la recuerdo. Cancelé su seguimiento (cada día a las 20:00).")
    }

    @Test func listingWhileDroppingRedirectsAndTheTurnIsForced() throws {
        let owner = "ya no quiero ahorrar, mejor quiero abonar a la deuda"
        #expect(LocalToolAdapter.intended(name: "list_goals", ownerText: owner) == "drop_goal")
        guard case .invalid(_, let message) = Self.resolve("list_goals", [:], owner: owner) else {
            Issue.record("esperaba redirect"); return
        }
        #expect(message == "El dueño pidió dejar una meta, no consultar: usa drop_goal.")
        let tools = [GoalsTool(otherModel: OtherModel(queue: try AnimaDatabase.temporary())).spec]
        let forced = OnDevicePromptBuilder.request(ctx: AssembledContext(messages: [.user(owner)]), tools: tools,
                                                   opts: try OnDeviceTestConfig.opts())
        #expect(forced.requiredQueryTool == "drop_goal")
        #expect(forced.tools.map(\.name).contains("drop_goal"))
        let reminder = OnDevicePromptBuilder.request(ctx: AssembledContext(messages: [.user("ya no quiero que me recuerdes lo del banco")]),
                                                     tools: tools, opts: try OnDeviceTestConfig.opts())
        #expect(reminder.requiredQueryTool == nil)
        #expect(LocalWhen.changeHint(owner) == "No la dejé todavía: dímelo de nuevo o elimínala en la tab Metas.")
    }
}

