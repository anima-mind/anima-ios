import Foundation
import GRDB
import Testing
@testable import AnimaKit

// Campo (2026-10-15): "le cambié una meta, le dije que ya no quería ahorrar sino
// abonar a una deuda y en el proceso de dreaming mantuvo las dos metas". En el
// teléfono seguía "Seguimiento · Ahorrar 30 millones de pesos para diciembre de
// 2026, cada miércoles a las 6:33 p. m." junto al recordatorio de abonar a la
// deuda. Estos tests emulan el transcript real (día 1 → día N → sueño) y solo
// usan la API previa al fix (tool por JSON, OtherModel.allGoals/desire,
// ProactiveScheduler): con el código anterior fallan (control negativo).

@Suite(.serialized) struct GoalReplacementFieldTests {

    static let oldStatement = "Ahorrar 30 millones de pesos para diciembre de 2026"
    static let day1Text = "Quiero ahorrar 30 millones de pesos para diciembre de 2026, pregúntame cada miércoles a las 6:33 pm"
    static let dayNText = "ya no quiero ahorrar, mejor quiero abonar a la deuda 5M cada quincena"

    struct World {
        let queue: DatabaseQueue
        /// nil = reloj real (el ciclo de sueño corre "ahora").
        let clock: Locked<Date?>
        let other: OtherModel
        let reminders: AnimaReminderStore
        let fake: FakeNotificationScheduler
        let scheduler: ProactiveScheduler
        let tool: GoalsTool
        let day1: Date
        let dayN: Date

        init() throws {
            queue = try AnimaDatabase.temporary()
            let clock = Locked<Date?>(nil)
            self.clock = clock
            let now: @Sendable () -> Date = { clock.value ?? Date() }
            other = OtherModel(queue: queue, now: now)
            reminders = AnimaReminderStore(queue: queue, now: now)
            fake = FakeNotificationScheduler(status: .granted)
            scheduler = ProactiveScheduler(scheduler: fake, reminders: reminders, otherModel: other)
            tool = GoalsTool(otherModel: other)
            day1 = Date().addingTimeInterval(-10 * 86_400)
            dayN = Date().addingTimeInterval(-2 * 86_400)
        }

        func at(_ date: Date?) { clock.mutate { $0 = date } }

        /// El AgentLoop encola el turno del dueño al recibirlo (antes de la tool).
        func owner(_ text: String, at date: Date) throws {
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO consolidation_inbox (session_id, text, source, created_at, cycle, consolidated_at)
                    VALUES ('s1', ?, 'turn', ?, NULL, NULL)
                    """, arguments: [text, date.timeIntervalSince1970])
            }
        }

        func consolidator(_ scripts: [[ProviderEvent]]) throws -> Consolidator {
            Consolidator(brain: Brain(queue: queue, embedder: Embedder(forceFallback: true)), queue: queue,
                         provider: ScriptedProvider(scripts), router: try .haikuAll(), authMode: .apiKey,
                         token: "sk-ant-api03-x", otherModel: other)
        }

        func open() async -> [Goal] { await other.allGoals().filter(\.isOpen) }

        /// Día 1: la meta de ahorro con su seguimiento de los miércoles 6:33 p. m. y
        /// un recordatorio ligado. Devuelve el id.
        func dayOne() async throws -> String {
            at(day1)
            try owner(GoalReplacementFieldTests.day1Text, at: day1)
            let declared = await tool.execute(.object([
                "action": .string("declare"), "statement": .string(GoalReplacementFieldTests.oldStatement),
                "checkin": .object(["cadence": .string("weekly"), "hour": .int(18), "minute": .int(33),
                                    "weekday": .int(4)]),
            ]))
            #expect(!declared.isError)
            let id = try #require(await other.allGoals().first?.id)
            _ = try await reminders.create(text: "Pasar 1M a la cuenta de ahorro", fireAt: day1.addingTimeInterval(20 * 86_400),
                                           goalId: id)
            return id
        }
    }

    /// Lo que un Haiku plausible devuelve al leer AMBOS mensajes con el formato
    /// previo (arreglo): re-extrae la meta vieja del día 1 y la nueva.
    static let legacyExtraction = [ProviderEvent].text("""
        [{"statement":"Ahorrar 30 millones de pesos para diciembre de 2026","evidence":"Quiero ahorrar 30 millones de pesos",
          "priority":8,"predicate":{"kind":"progress_check_in","every_days":8}},
         {"statement":"Abonar 5M a la deuda cada quincena","evidence":"mejor quiero abonar a la deuda 5M cada quincena",
          "priority":8,"predicate":{"kind":"progress_check_in","every_days":15}}]
        """)
    static let noFacts = [ProviderEvent].text("[]")

    static func onlyNewGoalIsLive(_ w: World, oldId: String) async throws {
        let open = await w.open()
        #expect(open.count == 1, "abiertas: \(open.map(\.statement))")
        let survivor = try #require(open.first)
        #expect(survivor.statement.lowercased().contains("deuda"))
        #expect(survivor.id != oldId)
        #expect(await w.other.goal(id: oldId)?.status == .abandoned)
        // El seguimiento viejo no se programa ni aparece en Recordatorios.
        let requests = await w.scheduler.desiredRequests()
        #expect(!requests.contains { $0.id.hasPrefix(ProactiveNotificationIDs.checkInPrefix + oldId) })
        let list = await MainActor.run { RemindersViewModel(store: w.reminders, otherModel: w.other) }
        await list.refresh()
        let titles = await MainActor.run { list.checkIns.map(\.title) }
        #expect(!titles.contains { $0.contains("Ahorrar") }, "\(titles)")
        // El recordatorio ligado a la meta vieja quedó cancelado (ya no se programa).
        #expect(!(await w.reminders.list(.upcoming)).contains { $0.goalId == oldId })
    }

    // MARK: - Conversación (modelo remoto) → sueño

    @Test func fieldScenarioReplaceInChatThenSleepKeepsOnlyTheNewGoal() async throws {
        let w = try World()
        let oldId = try await w.dayOne()
        #expect(await w.scheduler.desiredRequests().contains { $0.id.hasPrefix(ProactiveNotificationIDs.checkInPrefix) })

        // Día N: el modelo reemplaza (antes no existía la acción: creaba la nueva y la vieja quedaba).
        w.at(w.dayN)
        try w.owner(Self.dayNText, at: w.dayN)
        let replaced = await w.tool.execute(.object([
            "action": .string("replace"), "goal": .string("ahorrar"),
            "statement": .string("Abonar 5M a la deuda cada quincena"),
        ]))
        #expect(!replaced.isError, "\(replaced.content)")
        // Honesto: dice qué dejó y qué canceló.
        #expect(replaced.content.contains("Ahorrar 30 millones"))
        #expect(replaced.content.contains("seguimiento (cada miércoles a las 18:33)"))
        #expect(replaced.content.contains("Pasar 1M a la cuenta de ahorro"))

        // Noche: el sueño ve los dos mensajes y re-extrae la meta vieja; no la revive.
        w.at(nil)
        let report = try await w.consolidator([Self.noFacts, Self.legacyExtraction]).cycle()
        #expect(report.completed)
        try await Self.onlyNewGoalIsLive(w, oldId: oldId)
    }

    // MARK: - El sueño aplica el cambio que el chat no hizo (hipótesis b)

    @Test func sleepAppliesTheReplacementTheChatMissed() async throws {
        let w = try World()
        let oldId = try await w.dayOne()
        // Día N: el modelo solo declaró la nueva (la vieja quedó activa: el bug de campo).
        w.at(w.dayN)
        try w.owner(Self.dayNText, at: w.dayN)
        _ = await w.tool.execute(.object(["action": .string("declare"),
                                          "statement": .string("Abonar 5M a la deuda cada quincena")]))
        #expect(await w.open().count == 2)

        w.at(nil)
        let extraction = [ProviderEvent].text("""
            {"goals":[],"abandoned":[{"goal_id":null,"goal":"Ahorrar 30 millones de pesos para diciembre de 2026",
              "replaced_by":"Abonar 5M a la deuda cada quincena","evidence":"ya no quiero ahorrar","message":2}]}
            """)
        let report = try await w.consolidator([Self.noFacts, extraction]).cycle()
        #expect(report.completed)
        try await Self.onlyNewGoalIsLive(w, oldId: oldId)
    }

    // MARK: - El sueño no resucita una meta dejada en la tab Metas (hipótesis c)

    @Test func sleepDoesNotResurrectAGoalLeftInTheGoalsTab() async throws {
        let w = try World()
        let oldId = try await w.dayOne()
        // Día N: el dueño la elimina a mano en Metas (abandon), sin haber dormido desde el día 1.
        w.at(w.dayN)
        await w.other.abandon(id: oldId)

        w.at(nil)
        let extraction = [ProviderEvent].text("""
            [{"statement":"Ahorrar 30 millones para diciembre","evidence":"Quiero ahorrar 30 millones de pesos",
              "priority":8,"predicate":{"kind":"progress_check_in","every_days":8}}]
            """)
        _ = try await w.consolidator([Self.noFacts, extraction]).cycle()
        let open = await w.open()
        #expect(open.isEmpty, "\(open.map(\.statement))")
        #expect(await w.scheduler.desiredRequests().isEmpty)
    }

    // MARK: - Modelo local (Foundation Models, guionado)

    static func localTurn(_ w: World, _ scripts: [[OnDeviceStreamElement]], text: String) async throws -> [LoopEvent] {
        let store = SymbolicStore(queue: w.queue)
        let provider = OnDeviceProvider(session: MockOnDeviceSession(scripts), availability: { .available })
        let loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: w.queue),
                             router: try OnDeviceTestConfig.router(), authMode: .apiKey, token: "",
                             clientTools: [w.tool, AnimaRemindersTool(store: w.reminders)], serverTools: [],
                             permissionPolicy: .app(ownerAllowlist: { [] }), sleep: { _ in })
        let sid = try store.startSession()
        var events: [LoopEvent] = []
        for await event in await loop.run(sessionId: sid, userText: text) { events.append(event) }
        return events
    }

    static func text(_ events: [LoopEvent]) -> String {
        events.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }.joined()
    }

    @Test func localModelThatAnswersWithoutAToolStillReplacesTheGoal() async throws {
        let w = try World()
        let oldId = try await w.dayOne()
        w.at(w.dayN)
        // El 3B solo "responde" (medido en otras intenciones): el harness hace el cambio igual.
        let events = try await Self.localTurn(w, [[.snapshot("Entendido, ya no ahorrarás.")],
                                                  [.snapshot("Listo, cambié tu meta.")]], text: Self.dayNText)
        #expect(events.contains(.toolFinished(name: "goals", isError: false)), "\(events)")
        let open = await w.open()
        #expect(open.count == 1 && open.first?.statement.lowercased().contains("deuda") == true,
                "\(open.map(\.statement))")
        #expect(await w.other.goal(id: oldId)?.status == .abandoned)
        #expect(!(await w.scheduler.desiredRequests()).contains { $0.id.contains(oldId) })
        #expect(!Self.text(events).hasPrefix(ToolFailureNotice.marker))
    }

    @Test func localModelThatDeclaresTheNewGoalReplacesInstead() async throws {
        let w = try World()
        let oldId = try await w.dayOne()
        w.at(w.dayN)
        let events = try await Self.localTurn(w, [
            [.toolCall(name: "declare_goal", argumentsJSON: #"{"statement":"abonar a la deuda","checkin":"none","hour":20}"#)],
            [.snapshot("Listo, cambié tu meta de ahorrar por abonar a la deuda.")],
        ], text: Self.dayNText)
        #expect(events.contains(.toolFinished(name: "goals", isError: false)), "\(events)")
        let open = await w.open()
        #expect(open.count == 1 && open.first?.statement.lowercased().contains("deuda") == true,
                "\(open.map(\.statement))")
        #expect(await w.other.goal(id: oldId)?.status == .abandoned)
    }
}
