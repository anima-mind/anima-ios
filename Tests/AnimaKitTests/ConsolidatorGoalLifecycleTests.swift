import Foundation
import GRDB
import Testing
@testable import AnimaKit

// El sueño y las metas que el dueño deja (campo 2026-10-15): lo último que
// dijo gana, con guardas deterministas.

@Suite struct ConsolidatorGoalLifecycleTests {
    typealias F = GoalReplacementFieldTests
    static let noFacts = [ProviderEvent].text("[]")

    static func extraction(_ json: String) -> [ProviderEvent] { .text(json) }

    @Test func anAbandonmentWithoutACueInTheMessageIsIgnored() async throws {
        let w = try F.World()
        let id = try await w.dayOne()
        w.at(w.dayN)
        try w.owner("me encanta ahorrar, voy bien", at: w.dayN)
        w.at(nil)
        let json = #"{"goals":[],"abandoned":[{"goal_id":"\#(id)","goal":null,"replaced_by":null,"evidence":"me encanta ahorrar","message":2}]}"#
        _ = try await w.consolidator([Self.noFacts, Self.extraction(json)]).cycle()
        #expect(await w.other.goal(id: id)?.status == .active)
        // Tampoco si la cita no se puede ubicar.
        try w.owner("ya no quiero ahorrar", at: Date())
        let unplaced = #"{"goals":[],"abandoned":[{"goal_id":"\#(id)","goal":null,"replaced_by":null,"evidence":"algo que no dijo","message":null}]}"#
        _ = try await w.consolidator([Self.noFacts, Self.extraction(unplaced)]).cycle()
        #expect(await w.other.goal(id: id)?.status == .active)
    }

    @Test func theSleepLeavesAGoalByEvidenceAndTheWakeNoticeSaysSo() async throws {
        let w = try F.World()
        let id = try await w.dayOne()
        w.at(w.dayN)
        try w.owner("ya no quiero ahorrar", at: w.dayN)
        w.at(nil)
        let json = #"{"goals":[],"abandoned":[{"goal_id":null,"goal":"ahorrar","replaced_by":null,"evidence":"ya no quiero ahorrar","message":null}]}"#
        let report = try await w.consolidator([Self.noFacts, Self.extraction(json)]).cycle()
        #expect(await w.other.goal(id: id)?.status == .abandoned)
        #expect(report.goalsLeft == 1)
        let body = WakeNotice.body(report, night: 3, at: Date(timeIntervalSince1970: 1_791_300_600 + 9 * 3600),
                                   calendar: .current, slept: false)
        #expect(body.contains("1 meta que ya no querías, archivada con su seguimiento"), "\(body)")
        #expect(NightSimulator.summary(report, newGoals: 0).contains("1 meta archivada"))
        var two = report
        two.goalsLeft = 2
        #expect(WakeNotice.body(two, night: 3, at: Date(), calendar: .current).contains("2 metas que ya no querías"))
        #expect(NightSimulator.summary(two, newGoals: 0).contains("2 metas archivadas"))
    }

    @Test func aGoalDeclaredAgainAfterTheDropMessageIsKept() async throws {
        let w = try F.World()
        let id = try await w.dayOne()
        // El dueño dijo "ya no" el día N, pero después la volvió a declarar en el chat.
        w.at(w.dayN)
        try w.owner("ya no quiero ahorrar", at: w.dayN)
        w.at(w.dayN.addingTimeInterval(3600))
        _ = await w.tool.execute(.object(["action": .string("declare"), "statement": .string(F.oldStatement)]))
        w.at(nil)
        let json = #"{"goals":[],"abandoned":[{"goal_id":"\#(id)","goal":null,"replaced_by":null,"evidence":"ya no quiero ahorrar","message":2}]}"#
        _ = try await w.consolidator([Self.noFacts, Self.extraction(json)]).cycle()
        #expect(await w.other.goal(id: id)?.status == .active)
    }

    @Test func aRedeclarationLaterInTheCycleReactivatesTheLeftGoal() async throws {
        let w = try F.World()
        let id = try await w.dayOne()
        w.at(w.dayN)
        try w.owner("ya no quiero ahorrar", at: w.dayN)
        await w.other.abandon(id: id, reason: OtherModel.leftReason)
        let later = w.dayN.addingTimeInterval(86_400)
        try w.owner("sabes qué, sí quiero ahorrar 30 millones de pesos para diciembre de 2026", at: later)
        w.at(nil)
        let json = """
            {"goals":[{"statement":"\(F.oldStatement)","evidence":"sí quiero ahorrar 30 millones","message":3,
              "priority":8,"predicate":{"kind":"progress_check_in","every_days":8}}],"abandoned":[]}
            """
        _ = try await w.consolidator([Self.noFacts, Self.extraction(json)]).cycle()
        let goal = try #require(await w.other.goal(id: id))
        #expect(goal.status == .active)
        #expect(await w.other.allGoals().filter(\.isOpen).count == 1)
    }

    /// Medido con Haiku real: replaced_by trae el id de la meta nueva que ya existe.
    @Test func replacedByAnExistingGoalId() async throws {
        let w = try F.World()
        let id = try await w.dayOne()
        w.at(w.dayN)
        try w.owner(F.dayNText, at: w.dayN)
        let debt = await w.other.ingestStated(statement: "Abonar 5M a la deuda cada quincena",
                                              desiredState: .progressCheckIn(everyDays: 15), evidence: "chat")
        w.at(nil)
        let json = #"{"goals":[],"abandoned":[{"goal_id":"\#(id)","goal":"Ahorrar","replaced_by":"\#(debt)","evidence":"ya no quiero ahorrar","message":2}]}"#
        _ = try await w.consolidator([Self.noFacts, Self.extraction(json)]).cycle()
        let left = try #require(await w.other.goal(id: id))
        #expect(left.status == .abandoned && left.supersededBy == debt)
        #expect(await w.other.allGoals().filter(\.isOpen).map(\.id) == [debt])
        // replaced_by = la misma meta, o una ya cerrada: no se toca nada.
        let other = await w.other.ingestStated(statement: "Correr 10 km", desiredState: .progressCheckIn(everyDays: 7), evidence: "e")
        try w.owner("ya no quiero correr", at: Date())
        let selfRef = #"{"goals":[],"abandoned":[{"goal_id":"\#(other)","goal":null,"replaced_by":"\#(other)","evidence":"ya no quiero correr","message":1}]}"#
        _ = try await w.consolidator([Self.noFacts, Self.extraction(selfRef)]).cycle()
        #expect(await w.other.goal(id: other)?.status == .active)
    }

    @Test func thePromptCarriesIdsAndLeftGoals() async throws {
        let w = try F.World()
        let id = try await w.dayOne()
        let gone = await w.other.ingestStated(statement: "Correr 10 km", desiredState: .progressCheckIn(everyDays: 7), evidence: "e")
        await w.other.abandon(id: gone)
        w.at(nil)
        let provider = CapturingProvider([Self.noFacts, Self.extraction("[]")])
        let consolidator = Consolidator(brain: Brain(queue: w.queue, embedder: Embedder(forceFallback: true)), queue: w.queue,
                                        provider: provider, router: try .haikuAll(), authMode: .apiKey,
                                        token: "sk-ant-api03-x", otherModel: w.other)
        _ = try await consolidator.cycle()
        let prompt = try #require(provider.captures.value.last).messages
            .map { OnDevicePromptBuilder.plainText($0.content) }.joined(separator: "\n")
        #expect(prompt.contains("[\(id)] \(F.oldStatement) (declarada)"))
        #expect(prompt.contains("Metas que el dueño DEJÓ"))
        #expect(prompt.contains("- Correr 10 km"))
        #expect(prompt.contains("en orden cronológico"))
        #expect(Consolidator.goalsPrompt.contains("lo último que dijo el dueño gana"))
    }

    /// #42 (avisos por inactividad) va DESPUÉS de la extracción: una meta que el
    /// dueño dejó en el mismo ciclo no es contexto ni pregunta.
    @Test func reengagementNeverAsksAboutAGoalLeftInTheSameCycle() async throws {
        let w = try F.World()
        let old = try await w.dayOne()
        w.at(w.dayN)
        try w.owner(F.dayNText, at: w.dayN)
        _ = await w.tool.execute(.object(["action": .string("declare"),
                                          "statement": .string("Abonar 5M a la deuda cada quincena")]))
        w.at(nil)
        let extraction = Self.extraction("""
            {"goals":[],"abandoned":[{"goal_id":"\(old)","goal":null,"replaced_by":"Abonar 5M a la deuda cada quincena",
              "evidence":"ya no quiero ahorrar","message":2}]}
            """)
        let questions = [ProviderEvent].text(#"["¿Cómo vas con el ahorro?", "¿Cómo has estado estos días?", "¿Qué tal tu semana?"]"#)
        let provider = PromptCapturingProvider([Self.noFacts, extraction, questions])
        let store = ReengagementQuestionStore(queue: w.queue)
        let consolidator = Consolidator(brain: Brain(queue: w.queue, embedder: Embedder(forceFallback: true)),
                                        queue: w.queue, provider: provider, router: try .haikuAll(), authMode: .apiKey,
                                        token: "sk-ant-api03-x", otherModel: w.other, nudgeQuestions: store)
        #expect(try await consolidator.cycle().completed)
        #expect(await w.other.goal(id: old)?.status == .abandoned)
        let material = try #require(await consolidator.nudgeMaterial(cycle: 1))
        #expect(!material.goals.contains { $0.contains("Ahorrar") })
        #expect(material.goals.contains { $0.contains("deuda") })
        #expect(material.leftGoals == [F.oldStatement])
        let nudgePrompt = try #require(provider.users.value.last)
        #expect(nudgePrompt.contains("Metas que el dueño DEJÓ o cambió (NO preguntes por ellas):\n- \(F.oldStatement)"))
        #expect(!nudgePrompt.components(separatedBy: "Metas que el dueño DEJÓ")[0].contains("Ahorrar 30"))
        #expect(store.upcoming(limit: 10).map(\.text) == ["¿Cómo has estado estos días?", "¿Qué tal tu semana?"])
    }

    @Test func leftGoalQuestionsAreFilteredUnlessAboutAnActiveOne() {
        let left = ["Ahorrar 30 millones de pesos para diciembre de 2026"]
        #expect(ReengagementDraft.withoutLeftGoals(["¿Cómo vas con el ahorro?", "¿Qué tal tu semana?"],
                                                   left: left, active: []) == ["¿Qué tal tu semana?"])
        #expect(ReengagementDraft.withoutLeftGoals(["¿Cómo vas con el ahorro para el viaje?"], left: left,
                                                   active: ["Ahorrar para el viaje"]) == ["¿Cómo vas con el ahorro para el viaje?"])
        #expect(ReengagementDraft.withoutLeftGoals(["¿Cómo vas con el ahorro?"], left: [], active: []) == ["¿Cómo vas con el ahorro?"])
    }
}

