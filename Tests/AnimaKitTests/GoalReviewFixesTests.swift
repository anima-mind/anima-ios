import Foundation
import GRDB
import Testing
@testable import AnimaKit

// Review #45 (NO APROBADO): estos tests usan solo API previa al fix de la
// ronda (GoalDrop.parse, el adapter, la tool por JSON, OtherModel.abandon/
// reactivate, Sensorimotor, Consolidator, ActionClaimGuard): con 75cca70d
// fallan (control negativo).

/// Frases del review: el dueño NO deja ninguna meta.
let goalDropNegatives = [
    "mi amigo dejó de ahorrar", "ya no puedo ahorrar este mes", "ya no voy a poder ir al gym hoy",
    "olvida el gym por hoy", "ya no aguanto el gym", "ya no voy al gym", "ya no estoy tan seguro de correr el maratón",
    "quita el azúcar de mi dieta", "ya no tengo hambre", "olvida lo que dije de ahorrar, era broma",
    "mi amigo dejó de ahorrar y le fue mal", "estoy pensando en dejar de ahorrar", "ya no sé si ahorrar",
    "dejo el gym", "me rindo con el ahorro", "ya fue lo del ahorro",
]

/// El dueño deja (o cambia) la meta sin duda.
let goalDropPositives: [(String, String, String?)] = [
    ("ya no quiero ahorrar, mejor quiero abonar a la deuda 5M cada quincena", "ahorrar", "abonar a la deuda 5M cada quincena"),
    ("ya no quiero ahorrar", "ahorrar", nil),
    ("olvida mi meta de ahorrar", "ahorrar", nil),
    ("deja mi meta de correr", "correr", nil),
    ("borra mi meta de leer 12 libros", "leer 12 libros", nil),
    ("cambia mi meta de correr por nadar", "correr", "nadar"),
    ("abandono la meta de correr", "correr", nil),
    ("quiero abonar a la deuda en vez de ahorrar", "ahorrar", "abonar a la deuda"),
]

@Suite struct GoalDropReviewTests {
    @Test(arguments: goalDropNegatives)
    func neverDropsWithoutAClearFirstPersonIntent(text: String) {
        #expect(GoalDrop.parse(text) == nil)
        // El adapter no ejecuta la propuesta del 3B que el texto no respalda.
        let r = LocalToolAdapter.resolve(name: "drop_goal", input: .object(["goal": .string("ahorrar")]),
                                         now: Date(timeIntervalSince1970: 1_791_228_600), ownerText: text)
        if case .real(_, let input) = r {
            #expect(!["abandon", "replace"].contains(input["action"]?.stringValue ?? ""), "\(text) → \(input)")
        }
        let declared = LocalToolAdapter.resolve(name: "declare_goal", input: .object(["statement": .string("ahorrar")]),
                                                now: Date(timeIntervalSince1970: 1_791_228_600), ownerText: text)
        if case .real(_, let input) = declared {
            #expect(!["abandon", "replace"].contains(input["action"]?.stringValue ?? ""), "\(text) → \(input)")
        }
    }

    @Test(arguments: goalDropNegatives)
    func theLocalTurnIsNotForcedToDrop(text: String) throws {
        let tools = [GoalsTool(otherModel: OtherModel(queue: try AnimaDatabase.temporary())).spec]
        let request = OnDevicePromptBuilder.request(ctx: AssembledContext(messages: [.user(text)]), tools: tools,
                                                    opts: try OnDeviceTestConfig.opts())
        #expect(request.requiredQueryTool != "drop_goal")
    }

    @Test(arguments: goalDropPositives)
    func clearDropsStillWork(text: String, old: String, new: String?) throws {
        let parsed = try #require(GoalDrop.parse(text))
        #expect(parsed.old == old && parsed.new == new)
    }

    @Test func changeHintNoLongerSendsToTheTab() {
        let hint = LocalWhen.changeHint("quiero cambiar mi meta")
        #expect(hint?.contains("tab Metas") == false)
        #expect(hint?.contains("deja mi meta de") == true)
    }

    /// Medido (2 de 2, review): el 3B llamaba drop_goal y la meta se dejaba.
    @Test(arguments: ["mi amigo dejó de ahorrar", "ya no puedo ahorrar este mes", "olvida lo que dije de ahorrar, era broma"])
    func aLocalTurnThatCallsDropKeepsTheGoal(text: String) async throws {
        let w = try GoalReplacementFieldTests.World()
        let old = try await w.dayOne()
        w.at(w.dayN)
        let events = try await GoalReplacementFieldTests.localTurn(w, [
            [.toolCall(name: "drop_goal", argumentsJSON: #"{"goal":"ahorrar"}"#)],
            [.snapshot("Listo, dejé la meta.")],
        ], text: text)
        _ = events
        #expect(await w.other.goal(id: old)?.status == .active)
        #expect(await w.other.goal(id: old)?.checkIn.isActive == true)
    }
}

@Suite struct GoalReactivationRestoresTests {
    @Test func reactivateBringsBackTheCheckInAndFutureReminders() async throws {
        let w = try GoalLifecycleModelTests.World()
        let id = await w.other.ingestStated(statement: "Ahorrar 30 millones", desiredState: .progressCheckIn(everyDays: 8),
                                            evidence: "e")
        await w.other.setCheckIn(id: id, GoalLifecycleModelTests.weekly)
        let start = w.clock.value
        let future = try await w.reminders.create(text: "Pasar 1M al ahorro", fireAt: start.addingTimeInterval(10 * 86_400),
                                                  goalId: id)
        let soon = try await w.reminders.create(text: "Revisar la cuenta", fireAt: start.addingTimeInterval(3600), goalId: id)
        let weekly = try await w.reminders.create(text: "Contar el ahorro", fireAt: start.addingTimeInterval(1800),
                                                  repeat: .weekly, goalId: id)
        await w.other.abandon(id: id)
        #expect(await w.other.goal(id: id)?.checkIn.isActive == false)
        #expect(await w.reminders.reminder(id: future.id)?.status == .cancelled)
        // Pasan dos días: "Revisar la cuenta" ya pasó; el semanal sigue con su próxima ocurrencia.
        w.advance(2 * 86_400)
        #expect(await w.other.reactivate(id: id))
        let goal = try #require(await w.other.goal(id: id))
        #expect(goal.status == .active && goal.checkIn == GoalLifecycleModelTests.weekly)
        #expect(await w.reminders.reminder(id: future.id)?.status == .scheduled)
        #expect(await w.reminders.reminder(id: future.id)?.fireAt == start.addingTimeInterval(10 * 86_400))
        #expect(await w.reminders.reminder(id: soon.id)?.status == .cancelled)
        let again = try #require(await w.reminders.reminder(id: weekly.id))
        #expect(again.status == .scheduled && again.fireAt > w.clock.value)
        #expect(again.fireAt == start.addingTimeInterval(1800 + 7 * 86_400))
        // Dejarla de nuevo y reactivarla otra vez: sigue siendo reversible.
        await w.other.abandon(id: id)
        #expect(await w.other.reactivate(id: id))
        #expect(await w.other.goal(id: id)?.checkIn == GoalLifecycleModelTests.weekly)
    }

    @Test func aGoalWithoutFollowUpsReactivatesWithoutInventingOne() async throws {
        let w = try GoalLifecycleModelTests.World()
        let id = await w.other.ingestStated(statement: "Leer 12 libros", desiredState: .progressCheckIn(everyDays: 7), evidence: "e")
        await w.other.abandon(id: id)
        #expect(await w.other.reactivate(id: id))
        #expect(await w.other.goal(id: id)?.checkIn.isActive == false)
    }

    @Test func declaringItAgainInChatAlsoRestores() async throws {
        let w = try GoalLifecycleModelTests.World()
        let tool = GoalsTool(otherModel: w.other)
        let id = await w.other.ingestStated(statement: "Correr 10 km", desiredState: .progressCheckIn(everyDays: 7), evidence: "e")
        await w.other.setCheckIn(id: id, CheckInCadence(cadence: .daily, hour: 7))
        _ = try await w.reminders.create(text: "Correr el domingo", fireAt: w.clock.value.addingTimeInterval(86_400), goalId: id)
        await w.other.abandon(id: id)
        let result = await tool.execute(.object(["action": .string("declare"), "statement": .string("Correr 10 km")]))
        #expect(result.content.contains("Volvieron su seguimiento (cada día a las 07:00) y 1 recordatorio."), "\(result.content)")
        #expect(await w.other.goal(id: id)?.checkIn.cadence == .daily)
        #expect(await w.reminders.list(.upcoming).count == 1)
    }

    @Test func theToolPromiseMatchesWhatReactivateDoes() async throws {
        let w = try GoalLifecycleModelTests.World()
        let tool = GoalsTool(otherModel: w.other)
        let id = await w.other.ingestStated(statement: "Correr 10 km", desiredState: .progressCheckIn(everyDays: 7), evidence: "e")
        await w.other.setCheckIn(id: id, CheckInCadence(cadence: .daily, hour: 7))
        let result = await tool.execute(.object(["action": .string("abandon"), "goal_id": .string(id)]))
        #expect(result.content.contains("si la reactivas, vuelven su seguimiento y sus recordatorios"))
        #expect(await w.other.reactivate(id: id))
        #expect(await w.other.goal(id: id)?.checkIn.cadence == .daily)
    }
}

@Suite struct GoalSurfaceTests {
    static func request(_ op: String, _ surface: SurfaceID) -> ConfirmationRequest {
        ConfirmationRequest(tool: "goals", operation: op, summary: "Dejar la meta 'ahorrar'", input: .null, surface: surface)
    }

    @Test func carPlayAndSiriNeverDropAGoal() async throws {
        for surface in [SurfaceID.carplay, .siri] {
            let w = try GoalLifecycleModelTests.World()
            let id = await w.other.ingestStated(statement: "Ahorrar 30 millones", desiredState: .progressCheckIn(everyDays: 8),
                                                evidence: "e")
            let sensorimotor = Sensorimotor(tools: [GoalsTool(otherModel: w.other)], policy: .app(ownerAllowlist: { [] }))
            for input: JSONValue in [
                .object(["action": .string("abandon"), "goal": .string("ahorrar")]),
                .object(["action": .string("replace"), "goal": .string("ahorrar"), "statement": .string("Abonar a la deuda")]),
            ] {
                let result = await sensorimotor.execute(name: "goals", input: input, surface: surface)
                #expect(result.isError && result.content.contains("pendiente en el teléfono"), "\(surface): \(result.content)")
            }
            #expect(await w.other.goal(id: id)?.status == .active)
            #expect(await w.other.allGoals().count == 1)
            // Declarar sí se puede (reversible y no destruye nada).
            let declared = await sensorimotor.execute(name: "goals", input: .object([
                "action": .string("declare"), "statement": .string("Leer 12 libros")]), surface: surface)
            #expect(!declared.isError)
        }
        // En el teléfono, dejarla se hace (sin sheet).
        let w = try GoalLifecycleModelTests.World()
        let id = await w.other.ingestStated(statement: "Ahorrar 30 millones", desiredState: .progressCheckIn(everyDays: 8), evidence: "e")
        let sensorimotor = Sensorimotor(tools: [GoalsTool(otherModel: w.other)], policy: .app(ownerAllowlist: { [] }))
        let result = await sensorimotor.execute(name: "goals", input: .object(["action": .string("abandon"), "goal_id": .string(id)]))
        #expect(!result.isError)
        #expect(await w.other.goal(id: id)?.status == .abandoned)
    }

    @Test func carPlayDoesNotConfirmItByVoiceAndLeavesItPending() {
        for op in ["abandon", "replace"] {
            #expect(!CarPlayTurn.isVoiceConfirmable(Self.request(op, .carplay)))
            #expect(CarPlayTurn.refusal(for: Self.request(op, .carplay)) != nil)
            #expect(CarPlayTurn.leavesPending(Self.request(op, .carplay)))
        }
        #expect(CarPlayTurn.isVoiceConfirmable(Self.request("declare", .carplay)))
    }
}

@Suite(.serialized) struct ConsolidatorReviewTests {
    typealias F = GoalReplacementFieldTests
    static let noFacts = [ProviderEvent].text("[]")

    @Test(arguments: ["mi amigo dejó de ahorrar y le fue mal", "estoy pensando en dejar de ahorrar", "ya no sé si ahorrar"])
    func theSleepDoesNotDropOnAMereMention(text: String) async throws {
        let w = try F.World()
        let id = try await w.dayOne()
        w.at(w.dayN)
        try w.owner(text, at: w.dayN)
        w.at(nil)
        let json = #"{"goals":[],"abandoned":[{"goal_id":"\#(id)","goal":null,"replaced_by":null,"evidence":"\#(text)","message":2}]}"#
        _ = try await w.consolidator([Self.noFacts, .text(json)]).cycle()
        #expect(await w.other.goal(id: id)?.status == .active, "\(text)")
    }

    @Test func anInventedIdIsNeverAGoalStatement() async throws {
        let w = try F.World()
        let id = try await w.dayOne()
        w.at(w.dayN)
        try w.owner(F.dayNText, at: w.dayN)
        w.at(nil)
        let json = #"{"goals":[],"abandoned":[{"goal_id":"\#(id)","goal":null,"replaced_by":"11111111-2222-3333-4444-555555555555","evidence":"ya no quiero ahorrar","message":2}]}"#
        _ = try await w.consolidator([Self.noFacts, .text(json)]).cycle()
        let goals = await w.other.allGoals()
        #expect(!goals.contains { $0.statement.contains("1111") }, "\(goals.map(\.statement))")
        #expect(await w.other.goal(id: id)?.status == .abandoned)
        #expect(goals.filter(\.isOpen).isEmpty)
    }

    @Test func replacedByAnAchievedGoalStillLeavesTheOldOne() async throws {
        let w = try F.World()
        let id = try await w.dayOne()
        w.at(w.dayN)
        try w.owner(F.dayNText, at: w.dayN)
        let debt = await w.other.ingestStated(statement: "Abonar 5M a la deuda", desiredState: .progressCheckIn(everyDays: 15),
                                              evidence: "e")
        await w.other.markAchieved(id: debt)
        w.at(nil)
        let json = #"{"goals":[],"abandoned":[{"goal_id":"\#(id)","goal":null,"replaced_by":"\#(debt)","evidence":"ya no quiero ahorrar","message":2}]}"#
        _ = try await w.consolidator([Self.noFacts, .text(json)]).cycle()
        #expect(await w.other.goal(id: id)?.status == .abandoned)
        #expect(await w.other.goal(id: debt)?.status == .achieved)
    }

    @Test func theDropMustBeAboutThisGoal() async throws {
        let w = try F.World()
        let id = try await w.dayOne()
        w.at(w.dayN)
        try w.owner("ya no quiero correr", at: w.dayN)
        w.at(nil)
        let json = #"{"goals":[],"abandoned":[{"goal_id":"\#(id)","goal":null,"replaced_by":null,"evidence":"ya no quiero correr","message":2}]}"#
        _ = try await w.consolidator([Self.noFacts, .text(json)]).cycle()
        #expect(await w.other.goal(id: id)?.status == .active)
    }
}

@Suite struct ActionClaimReviewTests {
    @Test(arguments: ["Listo, cambié tu meta de ahorro por abonar a la deuda.", "Eliminé la meta de correr.",
                      "Archivé tu meta.", "Cancelé su seguimiento.", "Reemplacé tu meta por la nueva.", "Borré la meta de leer."])
    func goalChangesAreWriteClaims(text: String) {
        #expect(ActionClaimGuard.claimsWrite(text))
    }

    @Test(arguments: ["¿Quieres que cambie tu meta?", "No cancelé nada.", "Si quieres, la borro.", "Ya la había archivado ayer."])
    func offersAndNegationsAreNot(text: String) {
        #expect(!ActionClaimGuard.claimsWrite(text))
    }

    @Test func theNudgeNamesReplaceAndAbandon() {
        #expect(ActionClaimGuard.nudge.contains("goals replace o abandon"))
    }
}

@Suite struct ReengagementStemTests {
    @Test func leftGoalQuestionsAreFilteredByStem() {
        let left = ["Ahorrar 30 millones de pesos para diciembre de 2026"]
        #expect(ReengagementDraft.withoutLeftGoals(["¿Sigues ahorrando?", "¿Qué tal tu semana?"], left: left, active: [])
                == ["¿Qué tal tu semana?"])
    }
}
