import Foundation
import GRDB
import Testing
@testable import AnimaKit

// Dejar y reemplazar metas (campo 2026-10-15): el ciclo de vida en OtherModel,
// la tool `goals`, la migración v21 y la vista Metas.

@Suite struct GoalLifecycleModelTests {
    struct World {
        let queue: DatabaseQueue
        let clock: Locked<Date>
        let other: OtherModel
        let reminders: AnimaReminderStore
        init() throws {
            queue = try AnimaDatabase.temporary()
            let clock = Locked(Date(timeIntervalSince1970: 1_791_228_600))
            self.clock = clock
            other = OtherModel(queue: queue, now: { clock.value })
            reminders = AnimaReminderStore(queue: queue, now: { clock.value })
        }
        func advance(_ seconds: TimeInterval) { clock.mutate { $0 = $0.addingTimeInterval(seconds) } }
    }

    static let saving = "Ahorrar 30 millones de pesos para diciembre de 2026"
    static let debt = "Abonar 5M a la deuda cada quincena"
    static let weekly = CheckInCadence(cadence: .weekly, hour: 18, minute: 33, weekday: 4)

    @Test func replaceLeavesTheOldSupersededAndCancelsItsFollowUps() async throws {
        let w = try World()
        let old = await w.other.ingestStated(statement: Self.saving, desiredState: .progressCheckIn(everyDays: 8), evidence: "e")
        await w.other.setCheckIn(id: old, Self.weekly)
        let fire = w.clock.value.addingTimeInterval(86_400)
        let linked = try await w.reminders.create(text: "Pasar 1M a la cuenta de ahorro", fireAt: fire, goalId: old)
        let aboutDebt = try await w.reminders.create(text: "Abonar 5M a la deuda", fireAt: fire, goalId: old)
        w.advance(3600)

        let result = await w.other.replace(id: old, with: Self.debt, desiredState: .progressCheckIn(everyDays: 15),
                                           evidence: "chat")
        guard case .replaced(let new, let declaration, let abandonment) = result else {
            Issue.record("esperaba replaced: \(result)"); return
        }
        #expect(declaration.outcome == .created)
        #expect(new.statement == Self.debt && new.status == .active)
        let left = try #require(await w.other.goal(id: old))
        #expect(left.status == .abandoned && left.supersededBy == new.id)
        #expect(left.statusReason == OtherModel.replacedReason)
        #expect(left.abandonedAt == w.clock.value)
        #expect(!left.checkIn.isActive)
        #expect(abandonment.cancelledCheckIn == Self.weekly)
        #expect(abandonment.cancelledReminders == ["Pasar 1M a la cuenta de ahorro"])
        #expect(abandonment.movedReminders == ["Abonar 5M a la deuda"])
        #expect(await w.reminders.reminder(id: linked.id)?.status == .cancelled)
        #expect(await w.reminders.reminder(id: aboutDebt.id)?.goalId == new.id)
        #expect(await w.reminders.reminder(id: aboutDebt.id)?.status == .scheduled)
        #expect(await w.other.desire().map(\.id) == [new.id])
        // Ya cerrada: no se abandona dos veces.
        #expect(await w.other.abandon(id: old) == nil)
    }

    @Test func replacingWithTheSameGoalChangesNothing() async throws {
        let w = try World()
        let id = await w.other.ingestStated(statement: "Correr 5 km", desiredState: .progressCheckIn(everyDays: 7), evidence: "e")
        #expect(await w.other.replace(id: id, with: "correr 5 km cada semana", desiredState: .progressCheckIn(everyDays: 7),
                                      evidence: "e") == .same(try #require(await w.other.goal(id: id))))
        #expect(await w.other.replace(id: "nope", with: "x", desiredState: .progressCheckIn(everyDays: 7), evidence: "e")
                == .notFound)
        #expect(await w.other.goal(id: id)?.status == .active)
    }

    @Test func aDeclarationOlderThanTheAbandonmentNeverRevivesIt() async throws {
        let w = try World()
        let said = w.clock.value
        let id = await w.other.ingestStated(statement: Self.saving, desiredState: .progressCheckIn(everyDays: 8), evidence: "e")
        w.advance(86_400)
        await w.other.abandon(id: id, reason: OtherModel.leftReason)
        w.advance(86_400)
        // El sueño re-extrae el mensaje del día 1 (y una reformulación): la meta sigue dejada.
        let stale = await w.other.declare(statement: Self.saving, desiredState: .progressCheckIn(everyDays: 8),
                                          evidence: "e", statedAt: said)
        #expect(stale == GoalDeclaration(id: id, outcome: .staleAfterAbandon))
        let reworded = await w.other.declare(statement: "Ahorrar 30 millones para diciembre",
                                             desiredState: .progressCheckIn(everyDays: 8), evidence: "e", statedAt: said)
        #expect(reworded.outcome == .staleAfterAbandon)
        #expect(await w.other.desire().isEmpty)
        #expect(await w.other.allGoals().count == 1)
        // Declarada DESPUÉS del abandono: vuelve (la misma meta).
        let later = await w.other.declare(statement: Self.saving, desiredState: .progressCheckIn(everyDays: 8),
                                          evidence: "otra vez", statedAt: w.clock.value)
        #expect(later.id == id && later.outcome == .reactivated)
        let goal = try #require(await w.other.goal(id: id))
        #expect(goal.status == .active && goal.abandonedAt == nil && goal.supersededBy == nil)
        #expect(goal.declaredAt == w.clock.value)
    }

    @Test func matchOpenFindsTheGoalTheOwnerNames() async throws {
        let w = try World()
        #expect(await w.other.matchOpen("ahorrar") == .none)
        let saving = await w.other.ingestStated(statement: Self.saving, desiredState: .progressCheckIn(everyDays: 8), evidence: "e")
        #expect(await w.other.matchOpen("mi meta") == .one(try #require(await w.other.goal(id: saving))))
        let run = await w.other.ingestStated(statement: "Correr 10 km", desiredState: .progressCheckIn(everyDays: 7), evidence: "e")
        #expect(await w.other.matchOpen("ahorrar") == .one(try #require(await w.other.goal(id: saving))))
        #expect(await w.other.matchOpen(run) == .one(try #require(await w.other.goal(id: run))))
        _ = await w.other.ingestStated(statement: "Ahorrar para un carro", desiredState: .progressCheckIn(everyDays: 7), evidence: "e")
        guard case .ambiguous(let options) = await w.other.matchOpen("ahorrar") else {
            Issue.record("esperaba ambiguous"); return
        }
        #expect(options.count == 2)
        guard case .ambiguous = await w.other.matchOpen("la meta") else { Issue.record("varias abiertas"); return }
    }

    @Test func reactivateFromHistory() async throws {
        let w = try World()
        let id = await w.other.ingestStated(statement: "Leer 12 libros", desiredState: .progressCheckIn(everyDays: 7), evidence: "e")
        #expect(!(await w.other.reactivate(id: id)))
        await w.other.abandon(id: id)
        #expect(await w.other.leftGoals().map(\.id) == [id])
        #expect(await w.other.reactivate(id: id))
        #expect(await w.other.goal(id: id)?.status == .active)
        #expect(await w.other.leftGoals().isEmpty)
        // Con una abierta equivalente no se reactiva la vieja (una meta, una vez).
        await w.other.abandon(id: id)
        _ = await w.other.ingestStated(statement: "leer 12 libros", desiredState: .progressCheckIn(everyDays: 7), evidence: "e")
        #expect(await w.other.goal(id: id)?.status == .active)
        let other = await w.other.ingestStated(statement: "Correr", desiredState: .progressCheckIn(everyDays: 7), evidence: "e")
        await w.other.abandon(id: other)
        _ = await w.other.ingestStated(statement: "Correr", desiredState: .progressCheckIn(everyDays: 7), evidence: "e")
        await w.other.abandon(id: other)
        let fresh = try await w.queue.write { db -> String in
            try db.execute(sql: """
                INSERT INTO goal (id, statement, predicate_json, source, status, created_at, updated_at, declared_at)
                VALUES ('dup', 'Correr', '{}', 'stated', 'active', 0, 0, 0)
                """)
            return "dup"
        }
        #expect(!(await w.other.reactivate(id: fresh)))
        #expect(!(await w.other.reactivate(id: other)))
    }

    static func seededGoals(upTo migration: String) throws -> DatabaseQueue {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try AnimaDatabase.migrator().migrate(queue, upTo: migration)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO goal (id, statement, predicate_json, source, status, created_at, updated_at)
                VALUES ('a', 'Ahorrar 30 millones', '{}', 'stated', 'active', 100, 150),
                       ('b', 'Abonar a la deuda', '{}', 'stated', 'active', 200, 200),
                       ('c', 'Correr', '{}', 'stated', 'abandoned', 50, 80)
                """)
        }
        return queue
    }

    static func expectBackfill(_ queue: DatabaseQueue) throws {
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, status, superseded_by, abandoned_at, declared_at FROM goal ORDER BY id")
        }
        #expect(rows.map { $0["status"] as String } == ["active", "active", "abandoned"])
        #expect(rows.allSatisfy { ($0["superseded_by"] as String?) == nil })
        #expect(rows.map { $0["declared_at"] as Double? } == [100, 200, 50])
        #expect(rows.map { $0["abandoned_at"] as Double? } == [nil, nil, 80])
        let applied = try queue.read { try AnimaDatabase.migrator().appliedIdentifiers($0) }
        #expect(applied.contains("v19-reengagement-question") && applied.contains("v21-goal-lifecycle"))
        #expect(try queue.read { try $0.tableExists("reengagement_question") })
    }

    /// La migración registrada justo antes de v21 (v20-turn-quote cuando
    /// "responder citando" esté en el árbol; v19 si no): sin adivinar números.
    static func previous(to migration: String) throws -> String {
        let ids = AnimaDatabase.migrator().migrations
        let index = try #require(ids.firstIndex(of: migration))
        return ids[index - 1]
    }

    /// Una base en v18 (antes de los avisos por inactividad) sube v19 → … → v21.
    @Test func v18ThroughV19ToV21BackfillsDatesWithoutGuessingReplacements() throws {
        let queue = try Self.seededGoals(upTo: "v18-intention-turn-tag")
        try AnimaDatabase.migrator().migrate(queue, upTo: "v19-reengagement-question")
        try AnimaDatabase.migrator().migrate(queue)
        try Self.expectBackfill(queue)
    }

    /// Una base que ya tiene todo lo anterior (v19 avisos por inactividad, y v20
    /// si está en el árbol) aplica solo v21.
    @Test func previousToV21() throws {
        let previous = try Self.previous(to: "v21-goal-lifecycle")
        let queue = try Self.seededGoals(upTo: previous)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO reengagement_question (id, text, cycle, rank, created_at) VALUES ('q', '¿Cómo vas?', 1, 0, 10)
                """)
        }
        let migrator = AnimaDatabase.migrator()
        let before = try queue.read { try migrator.appliedIdentifiers($0) }
        #expect(before.contains("v19-reengagement-question") && !before.contains("v21-goal-lifecycle"))
        try migrator.migrate(queue)
        try Self.expectBackfill(queue)
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM reengagement_question") } == 1)
        let ids = migrator.migrations
        let v19 = try #require(ids.firstIndex(of: "v19-reengagement-question"))
        let v21 = try #require(ids.firstIndex(of: "v21-goal-lifecycle"))
        #expect(v19 < v21)
        #expect(!ids.contains("v20-goal-lifecycle"))
    }
}

@Suite struct GoalsToolLifecycleTests {
    typealias W = GoalLifecycleModelTests.World

    @Test func abandonByTheOwnersWordsSaysWhatItCancelled() async throws {
        let w = try W()
        let tool = GoalsTool(otherModel: w.other)
        let empty = await tool.execute(.object(["action": .string("abandon"), "goal": .string("ahorrar")]))
        #expect(empty.isError && empty.content.contains("no existe una meta"))
        let id = await w.other.ingestStated(statement: GoalLifecycleModelTests.saving,
                                            desiredState: .progressCheckIn(everyDays: 8), evidence: "e")
        await w.other.setCheckIn(id: id, GoalLifecycleModelTests.weekly)
        let result = await tool.execute(.object(["action": .string("abandon"), "goal": .string("ahorrar")]))
        #expect(!result.isError)
        #expect(result.content == "Listo: dejé la meta «\(GoalLifecycleModelTests.saving)» (id \(id)); ya no te la recuerdo. "
                + "Cancelé su seguimiento (cada miércoles a las 18:33). Queda en Metas → Historial: si la reactivas, vuelven "
                + "su seguimiento y sus recordatorios.")
        #expect(await w.other.goal(id: id)?.statusReason == OtherModel.leftReason)
        let again = await tool.execute(.object(["action": .string("abandon"), "goal_id": .string(id)]))
        #expect(again.isError)
        let missing = await tool.execute(.object(["action": .string("abandon")]))
        #expect(missing.isError && missing.content.contains("falta 'goal_id' o 'goal'"))
    }

    @Test func ambiguousOrMissingReferencesAreRetryableErrors() async throws {
        let w = try W()
        let tool = GoalsTool(otherModel: w.other)
        _ = await w.other.ingestStated(statement: "Ahorrar para un carro", desiredState: .progressCheckIn(everyDays: 7), evidence: "e")
        _ = await w.other.ingestStated(statement: GoalLifecycleModelTests.saving, desiredState: .progressCheckIn(everyDays: 7),
                                       evidence: "e")
        let result = await tool.execute(.object(["action": .string("abandon"), "goal": .string("ahorrar")]))
        #expect(result.isError && result.content.contains("no identifica una sola meta"))
        #expect(result.content.contains("Ahorrar para un carro") && result.content.contains("30 millones"))
        let noStatement = await tool.execute(.object(["action": .string("replace"), "goal": .string("carro")]))
        #expect(noStatement.isError && LocalToolAdapter.isParameterError(noStatement.content))
        let badCheckIn = await tool.execute(.object(["action": .string("replace"), "goal": .string("carro"),
                                                     "statement": .string("x"), "checkin": .object(["cadence": .string("x")])]))
        #expect(badCheckIn.isError)
        let badPredicate = await tool.execute(.object(["action": .string("replace"), "goal": .string("carro"),
                                                       "statement": .string("x"), "predicate": .object(["kind": .string("x")])]))
        #expect(badPredicate.isError)
        let unknownId = await tool.execute(.object(["action": .string("replace"), "goal_id": .string("nope"),
                                                    "statement": .string("x")]))
        #expect(unknownId.isError)
    }

    @Test func replaceWithACheckInAndTheSameGoal() async throws {
        let w = try W()
        var changes = 0
        let counter = Locked(0)
        let tool = GoalsTool(otherModel: w.other, onChange: { counter.mutate { $0 += 1 } })
        let id = await w.other.ingestStated(statement: "Correr 5 km", desiredState: .progressCheckIn(everyDays: 7), evidence: "e")
        let same = await tool.execute(.object(["action": .string("replace"), "goal_id": .string(id),
                                               "statement": .string("correr 5 km")]))
        #expect(!same.isError && same.content.hasPrefix("Es la misma meta"))
        let result = await tool.execute(.object([
            "action": .string("replace"), "goal_id": .string(id), "statement": .string("Nadar 2 km"),
            "checkin": .object(["cadence": .string("daily"), "hour": .int(7)]),
        ]))
        #expect(!result.isError)
        #expect(result.content.contains("cambié la meta «Correr 5 km» por «Nadar 2 km»"))
        #expect(result.content.contains("Por la nueva te pregunto cada día a las 07:00."))
        let new = try #require(await w.other.desire().first)
        #expect(new.statement == "Nadar 2 km" && new.checkIn.cadence == .daily)
        changes = counter.value
        #expect(changes == 1)
        let plain = await tool.execute(.object(["action": .string("replace"), "goal_id": .string(new.id),
                                                "statement": .string("Nadar 3 km")]))
        #expect(plain.content.contains("Cancelé su seguimiento (cada día a las 07:00)."))
        #expect(plain.content.contains("La nueva no tiene seguimiento todavía."))
    }

    @Test func declaringALeftGoalAgainReactivatesIt() async throws {
        let w = try W()
        let tool = GoalsTool(otherModel: w.other)
        let id = await w.other.ingestStated(statement: "Leer 12 libros", desiredState: .progressCheckIn(everyDays: 7), evidence: "e")
        await w.other.abandon(id: id)
        let result = await tool.execute(.object(["action": .string("declare"), "statement": .string("leer 12 libros")]))
        #expect(result.content == "La habías dejado y la reactivé (id \(id)): leer 12 libros.")
        #expect(await w.other.goal(id: id)?.status == .active)
    }

    @Test func specSummaryPolicyAndNotice() {
        let tool = GoalsTool(otherModel: OtherModel(queue: try! AnimaDatabase.temporary()))
        guard case .client(_, let description, let schema) = tool.spec else { Issue.record("client"); return }
        #expect(description.contains("replace") && description.contains("NUNCA declares la nueva dejando la vieja activa"))
        let actions = schema["properties"]?["action"]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(actions.contains("abandon") && actions.contains("replace"))
        #expect(tool.kind(for: .object(["action": .string("abandon")])) == .efferent)
        #expect(tool.confirmationSummary(for: .object(["action": .string("abandon"), "goal": .string("ahorrar")]))
                == "Dejar la meta 'ahorrar'")
        #expect(tool.confirmationSummary(for: .object(["action": .string("replace"), "goal": .string("ahorrar"),
                                                        "statement": .string("abonar a la deuda")]))
                == "Cambiar la meta 'ahorrar' por 'abonar a la deuda'")
        let policy = PermissionPolicy.app(ownerAllowlist: { [] })
        for op in ["abandon", "replace"] {
            #expect(policy.decide(tool: "goals", known: true, kind: .efferent, operation: op) == .allow)
        }
        #expect(ToolFailureNotice.verb(tool: "goals", input: .object(["action": .string("abandon")])) == "dejar la meta")
        #expect(ToolFailureNotice.verb(tool: "goals", input: .object(["action": .string("replace")])) == "cambiar la meta")
    }
}

@MainActor
@Suite struct GoalsViewLifecycleTests {
    @Test func historyLabelsAndReactivate() async throws {
        let queue = try AnimaDatabase.temporary()
        let other = OtherModel(queue: queue)
        let model = GoalsViewModel(otherModel: other)
        let synced = Locked(0)
        model.onCheckInChanged = { synced.mutate { $0 += 1 } }
        let old = await other.ingestStated(statement: "Ahorrar 30 millones", desiredState: .progressCheckIn(everyDays: 8), evidence: "e")
        let run = await other.ingestStated(statement: "Correr", desiredState: .progressCheckIn(everyDays: 8), evidence: "e")
        _ = await other.replace(id: old, with: "Abonar a la deuda", desiredState: .progressCheckIn(everyDays: 15), evidence: "e")
        await model.refresh()
        let left = try #require(model.pastGoals.first { $0.id == old })
        #expect(model.pastLabel(left) == "reemplazada por «Abonar a la deuda»")
        let runGoal = try #require(model.currentGoals.first { $0.id == run })
        await model.delete(runGoal)
        let deleted = try #require(model.pastGoals.first { $0.id == run })
        #expect(model.pastLabel(deleted) == "abandonada")
        #expect(GoalsViewModel.canReactivate(deleted))
        await model.reactivate(deleted)
        #expect(model.currentGoals.contains { $0.id == run })
        #expect(synced.value == 2)
        var dup = deleted
        dup.statusReason = GoalMerge.reason
        #expect(!GoalsViewModel.canReactivate(dup))
        var achieved = deleted
        achieved.status = .achieved
        #expect(model.pastLabel(achieved) == "lograda")
        var orphan = deleted
        orphan.supersededBy = "gone"
        #expect(model.pastLabel(orphan) == "reemplazada")
    }
}
