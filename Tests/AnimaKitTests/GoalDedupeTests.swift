import Foundation
import Testing
import GRDB
@testable import AnimaKit

// Campo batch 8 #5: "las metas se siguen duplicando cada noche; solo una vez".
// La misma meta existía 3 veces. Causa real: OtherModel.upsert deduplicaba
// solo por enunciado EXACTO; la extracción nocturna pedía "tercera persona"
// ("El dueño quiere bajar 10 kg"), el reflection infería sin ver las
// existentes ("Perder 10 kg en un plazo determinado") y el chat declaraba con
// las palabras del dueño ("Bajar 10 kg de peso"). Una inferida rechazada
// (abandonada) además volvía a nacer cada noche.

@Suite("Batch 8 #5 — dedupe semántico determinista")
struct GoalDedupeTests {
    static let field = ["El dueño quiere bajar 10 kg", "Perder 10 kg en un plazo determinado", "Bajar 10 kg de peso"]

    @Test func losTresEnunciadosDeCampoSonLaMismaMeta() {
        for a in Self.field { for b in Self.field { #expect(GoalDedupe.equivalent(a, b), "\(a) ≈ \(b)") } }
        #expect(GoalDedupe.equivalent("Quiero bajar 10kg", "reducir 10 kilos"))
        #expect(GoalDedupe.equivalent("Mi meta es entrenar 3 veces por semana", "Ir al gimnasio 3 veces por semana"))
    }

    @Test func metasDistintasNoSeFusionan() {
        #expect(!GoalDedupe.equivalent("Bajar 10 kg", "Bajar 5 kg"))
        #expect(!GoalDedupe.equivalent("Bajar 10 kg", "Ahorrar 10 millones"))
        #expect(!GoalDedupe.equivalent("Dormir 7 horas", "Leer 20 minutos"))
        #expect(!GoalDedupe.equivalent("Correr", "Correr una maratón"))
        #expect(!GoalDedupe.equivalent("", "Bajar 10 kg"))
    }

    /// Review #34: el subconjunto solo vale si lo de más es cadencia.
    @Test func noFundeMetasDistintasConPalabrasComunes() {
        #expect(!GoalDedupe.equivalent("Correr una maratón", "Correr una media maratón"))
        #expect(!GoalDedupe.equivalent("Aprender inglés", "Aprender inglés y francés"))
        #expect(!GoalDedupe.equivalent("Aprender inglés y francés", "Aprender francés"))
        #expect(!GoalDedupe.equivalent("Bajar el azúcar", "Eliminar el azúcar"))
        #expect(GoalDedupe.equivalent("Correr 5 km", "Correr 5 km cada semana"))
        #expect(GoalDedupe.equivalent("Leer", "Leer todos los días"))
    }

    /// Ronda 2: periodos explícitos distintos no se funden; si uno no trae
    /// periodo, el marcador se ignora. Igual en la copia congelada de v17.
    @Test func periodosDistintosSonMetasDistintas() {
        let different = [("Leer 1 libro al mes", "Leer 1 libro a la semana"),
                         ("Ahorrar 1 millón al mes", "Ahorrar 1 millón al año"),
                         ("Correr 5 km cada día", "Correr 5 km cada semana"),
                         ("Ahorrar 200 mil cada quincena", "Ahorrar 200 mil mensual")]
        for (a, b) in different {
            #expect(!GoalDedupe.equivalent(a, b), "\(a) ≠ \(b)")
            #expect(!V17Dedupe.equivalent(a, b), "v17: \(a) ≠ \(b)")
        }
        let same = [("Leer 1 libro", "Leer 1 libro al mes"), ("Ahorrar 1 millón al mes", "Ahorrar 1 millón mensual"),
                    ("Correr 5 km", "Correr 5 km cada semana")]
        for (a, b) in same {
            #expect(GoalDedupe.equivalent(a, b), "\(a) ≈ \(b)")
            #expect(V17Dedupe.equivalent(a, b), "v17: \(a) ≈ \(b)")
        }
    }

    @Test func enunciadoNeutralNuncaElDuenoQuiere() {
        #expect(GoalDedupe.neutral("El dueño quiere bajar 10 kg") == "Bajar 10 kg")
        #expect(GoalDedupe.neutral("Joshua quiere entrenar 3x por semana.") == "Entrenar 3x por semana")
        #expect(GoalDedupe.neutral("quiero leer más") == "Leer más")
        #expect(GoalDedupe.neutral("Mi meta es ahorrar 10 millones") == "Ahorrar 10 millones")
        #expect(GoalDedupe.neutral("Bajar 10 kg de peso") == "Bajar 10 kg de peso")
        #expect(GoalDedupe.neutral("  ") == "")
    }
}

@Suite("Batch 8 #5 — OtherModel crea una meta una sola vez")
struct GoalDedupeModelTests {

    @Test func losTresEnunciadosDejanUnaSolaMeta() async throws {
        let other = OtherModel(queue: try AnimaDatabase.temporary())
        let a = await other.ingestStated(statement: GoalDedupeTests.field[0], desiredState: .progressCheckIn(everyDays: 7),
                                         evidence: "noche 1")
        let b = await other.infer(statement: GoalDedupeTests.field[1], desiredState: .progressCheckIn(everyDays: 7),
                                  evidence: "reflection")
        let c = await other.ingestStated(statement: GoalDedupeTests.field[2], desiredState: .progressCheckIn(everyDays: 7),
                                         evidence: "declarada en el chat")
        #expect(a == b && b == c)
        let goals = await other.allGoals()
        #expect(goals.count == 1)
        #expect(goals.first?.statement == "Bajar 10 kg")
        #expect(goals.first?.source == .stated)
        #expect(goals.first?.evidence == "declarada en el chat")   // refuerza evidencia
    }

    @Test func unaDeclaradaPromueveLaInferidaEquivalente() async throws {
        let other = OtherModel(queue: try AnimaDatabase.temporary())
        let inferred = await other.infer(statement: "Perder 10 kg", desiredState: .progressCheckIn(everyDays: 7),
                                         evidence: "r")
        #expect(await other.pendingConfirmations().count == 1)
        let stated = await other.ingestStated(statement: "Quiero bajar 10 kilos", desiredState: .progressCheckIn(everyDays: 7),
                                              evidence: "chat")
        #expect(stated == inferred)
        let goal = try #require(await other.goal(id: stated))
        #expect(goal.source == .stated && goal.status == .active && goal.motivates)
        #expect(goal.statement == "Bajar 10 kilos")
        #expect(await other.pendingConfirmations().isEmpty)
    }

    @Test func unaInferidaRechazadaNoRenaceCadaNoche() async throws {
        let other = OtherModel(queue: try AnimaDatabase.temporary())
        let id = await other.infer(statement: "Dormir 7 horas", desiredState: .progressCheckIn(everyDays: 1), evidence: "r")
        await other.abandon(id: id)
        let again = await other.infer(statement: "Dormir 7 horas cada noche", desiredState: .progressCheckIn(everyDays: 1),
                                      evidence: "r2")
        #expect(again == id)
        #expect(await other.allGoals().count == 1)
        #expect(await other.pendingConfirmations().isEmpty)
        // Declararla de nuevo sí la revive como nueva (el dueño la quiere).
        _ = await other.ingestStated(statement: "Dormir 7 horas", desiredState: .progressCheckIn(everyDays: 1), evidence: "c")
        #expect(await other.desire().count == 1)
    }

    /// Review #34: una meta LOGRADA no absorbe una nueva equivalente.
    @Test func unaLogradaNoAbsorbeLaNueva() async throws {
        let other = OtherModel(queue: try AnimaDatabase.temporary())
        let done = await other.ingestStated(statement: "Correr 5 km", desiredState: .progressCheckIn(everyDays: 7),
                                            evidence: "e")
        await other.markAchieved(id: done)
        let again = await other.ingestStated(statement: "Correr 5 km", desiredState: .progressCheckIn(everyDays: 7),
                                             evidence: "otra vez")
        #expect(again != done)
        #expect(await other.goal(id: again)?.status == .active)
        #expect(await other.goal(id: done)?.status == .achieved)
        let tool = GoalsTool(otherModel: other)
        await other.markAchieved(id: again)
        let result = await tool.execute(.object(["action": .string("declare"), "statement": .string("Correr 5 km")]))
        #expect(result.content.hasPrefix("Meta registrada"))
        #expect(await other.mergeDuplicates() == 0)
    }

    @Test func laFusionEnCalienteNoEsTransitivaNiTocaLogradas() async throws {
        let other = OtherModel(queue: try AnimaDatabase.temporary())
        let english = await other.ingestStated(statement: "Aprender inglés", desiredState: .progressCheckIn(everyDays: 7),
                                               evidence: "e")
        // Sin dedupe en la entrada: se insertan por la migración vieja / datos legacy.
        let both = await other.ingestStated(statement: "Aprender inglés y francés",
                                            desiredState: .progressCheckIn(everyDays: 7), evidence: "e")
        let french = await other.ingestStated(statement: "Aprender francés", desiredState: .progressCheckIn(everyDays: 7),
                                              evidence: "e")
        #expect(Set([english, both, french]).count == 3)
        #expect(await other.mergeDuplicates() == 0)
        #expect(await other.allGoals().allSatisfy { $0.status == .active })
    }

    @Test func laToolAvisaQueYaExistia() async throws {
        let other = OtherModel(queue: try AnimaDatabase.temporary())
        let tool = GoalsTool(otherModel: other)
        let first = await tool.execute(.object(["action": .string("declare"), "statement": .string("Bajar 10 kg de peso")]))
        #expect(first.content.hasPrefix("Meta registrada"))
        let second = await tool.execute(.object(["action": .string("declare"),
                                                 "statement": .string("El dueño quiere bajar 10 kg")]))
        #expect(second.content.hasPrefix("Esa meta ya existía"))
        #expect(await other.allGoals().count == 1)
        #expect(await other.existingStatements() == ["Bajar 10 kg de peso (declarada)"])
    }
}

@Suite("Batch 8 #5 — migración que fusiona los duplicados existentes")
struct GoalMergeMigrationTests {

    @Test func fusionaConservandoLaDeclaradaMasAntiguaConSuSeguimiento() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try AnimaDatabase.migrator().migrate(queue, upTo: "v15-context-boundary")
        // Estado de campo: 3 filas de la misma meta (antes del dedupe).
        try await queue.write { db in
            func insert(_ id: String, _ statement: String, _ source: String, _ status: String, _ at: Double,
                        cadence: String = "none") throws {
                try db.execute(sql: """
                    INSERT INTO goal (id, statement, predicate_json, source, status, priority, evidence,
                                      confirmed_by_other, created_at, updated_at, checkin_cadence, checkin_hour)
                    VALUES (?,?,?,?,?,5,'e',0,?,?,?,8)
                    """, arguments: [id, statement, #"{"progressCheckIn":{"everyDays":7}}"#, source, status, at, at, cadence])
            }
            try insert("g1", "El dueño quiere bajar 10 kg", "stated", "active", 100)
            try insert("g2", "Perder 10 kg en un plazo determinado", "inferred", "pending_confirmation", 200)
            try insert("g3", "Bajar 10 kg de peso", "stated", "active", 300, cadence: "weekly")
            try insert("g4", "Ahorrar 10 millones", "stated", "active", 400)
            try db.execute(sql: "INSERT INTO goal_checkin (id, goal_id, asked_at) VALUES ('c1','g3',350)")
            try db.execute(sql: """
                INSERT INTO anima_reminder (id, text, fire_at, goal_id, status, created_at)
                VALUES ('r1','check-in',9999999999,'g3','scheduled',350)
                """)
        }
        try AnimaDatabase.migrator().migrate(queue)

        let other = OtherModel(queue: queue)
        let alive = await other.allGoals().filter { $0.status != .abandoned }
        #expect(Set(alive.map(\.id)) == ["g1", "g4"])
        let keeper = try #require(await other.goal(id: "g1"))
        #expect(keeper.statement == "Bajar 10 kg")
        #expect(keeper.checkIn.cadence == .weekly)   // la cadencia de la duplicada no se pierde
        for dup in ["g2", "g3"] {
            let goal = try #require(await other.goal(id: dup))
            #expect(goal.status == .abandoned && goal.statusReason == GoalMerge.reason)
        }
        #expect(await other.checkIns(goalId: "g1").map(\.id) == ["c1"])
        let reminder = try await queue.read { db in try String.fetchOne(db, sql: "SELECT goal_id FROM anima_reminder WHERE id='r1'") }
        #expect(reminder == "g1")
        // Idempotente.
        #expect(await other.mergeDuplicates() == 0)
    }

    /// Review #34: v17 no abandona una activa por una LOGRADA equivalente, y
    /// agrupa sin transitividad.
    @Test func laMigracionSoloFusionaAbiertasYSinTransitividad() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try AnimaDatabase.migrator().migrate(queue, upTo: "v15-context-boundary")
        try await queue.write { db in
            func insert(_ id: String, _ statement: String, _ status: String, _ at: Double) throws {
                try db.execute(sql: """
                    INSERT INTO goal (id, statement, predicate_json, source, status, priority, evidence,
                                      confirmed_by_other, created_at, updated_at)
                    VALUES (?,?,'{}','stated',?,5,'e',0,?,?)
                    """, arguments: [id, statement, status, at, at])
            }
            try insert("done", "Correr 5 km", "achieved", 100)
            try insert("run", "Correr 5 km cada semana", "active", 200)
            try insert("en", "Aprender inglés", "active", 300)
            try insert("enfr", "Aprender inglés y francés", "active", 400)
            try insert("fr", "Aprender francés", "active", 500)
        }
        try AnimaDatabase.migrator().migrate(queue)
        let other = OtherModel(queue: queue)
        for id in ["run", "en", "enfr", "fr"] { #expect(await other.goal(id: id)?.status == .active, "\(id)") }
        #expect(await other.goal(id: "done")?.status == .achieved)
    }
}

/// El sueño ×3 noches con un modelo que en cada noche reformula la meta y el
/// reflection la infiere de nuevo: queda UNA meta.
@Suite("Batch 8 #5 — tres noches, una meta")
struct GoalThreeNightsTests {

    /// Responde por etapa (según el system prompt del Consolidator).
    final class NightProvider: Provider, @unchecked Sendable {
        let night = Locked(0)
        let statements = ["El dueño quiere bajar 10 kg", "Bajar 10 kg de peso", "Reducir 10 kilos"]
        let goalPrompts = Locked<[String]>([])

        func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
            -> AsyncThrowingStream<ProviderEvent, Error> {
            let system = opts.systemPromptBase
            let user = ctx.messages.last.map { OnDevicePromptBuilder.plainText($0.content) } ?? ""
            let n = night.value
            let reply: String
            if system == Consolidator.goalsPrompt {
                goalPrompts.mutate { $0.append(user) }
                reply = #"[{"statement":"\#(statements[n % 3])","evidence":"quiero bajar 10 kg","priority":7,"predicate":{"kind":"progress_check_in","every_days":7}}]"#
            } else if system == Consolidator.reflectionPrompt {
                reply = #"{"summary":"quiere bajar de peso","insights":[],"inferred_goals":[{"statement":"Perder 10 kg en un plazo determinado","rationale":"lo repite","priority":6,"predicate":{"kind":"progress_check_in","every_days":7}}]}"#
            } else if system == Consolidator.distillPrompt {
                reply = #"[{"content":"Tiene como meta bajar 10 kg (noche \#(n))","kind":"semantic","importance":7}]"#
            } else if system == Consolidator.decisionPrompt {
                reply = #"{"decision":"ADD","target_id":null,"reason":"nuevo"}"#
            } else {
                reply = #"{"action":"keep"}"#
            }
            return AsyncThrowingStream { continuation in
                for event in [ProviderEvent].text(reply) { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    @Test func tresNochesDejanUnaSolaMeta() async throws {
        let queue = try AnimaDatabase.temporary()
        let brain = Brain(queue: queue, embedder: Embedder(forceFallback: true))
        let inbox = ConsolidationInbox(queue: queue)
        let other = OtherModel(queue: queue)
        let provider = NightProvider()
        let consolidator = Consolidator(brain: brain, queue: queue, provider: provider, router: try .haikuAll(),
                                        authMode: .apiKey, token: "sk-ant-api03-x", otherModel: other)
        for n in 0..<3 {
            provider.night.mutate { $0 = n }
            try inbox.enqueue(sessionId: "s\(n)", text: "Quiero bajar 10 kg, noche \(n)")
            let report = try await consolidator.cycle()
            #expect(report.completed)
        }
        let goals = await other.allGoals()
        #expect(goals.count == 1, "\(goals.map(\.statement))")
        #expect(goals.first?.source == .stated)
        #expect(!(goals.first?.statement.lowercased().hasPrefix("el dueño") ?? true))
        // Desde la 2.ª noche el modelo ve la lista de metas existentes.
        let prompts = provider.goalPrompts.value
        #expect(prompts.count == 3)
        // Noche 1: el reflection ya había inferido la meta → la extracción la ve.
        #expect(prompts[0].contains("Metas que YA existen") && prompts[0].contains("(inferida)"))
        #expect(prompts[1].contains("Metas que YA existen") && prompts[1].contains("Bajar 10 kg (declarada)"))
    }
}
