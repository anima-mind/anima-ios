import Foundation
import Testing
import GRDB
@testable import AnimaKit

// Campo batch 3 / FIX B: memorias BASURA reales del dispositivo del dueño. El
// guard determinista las rechaza; los hechos legítimos pasan.

@Suite("Campo — DistillGuard (destilado v2)")
struct DistillGuardTests {

    /// Las 4 memorias reales de producción: CERO valor.
    static let realGarbage: [(String, DistillGuard.Rejection)] = [
        ("Que tengo pendiente en mi agenda?", .question),
        ("Que modelo usas para responder?", .question),
        ("Betty cuéntame sobre cómo funcionas", .question),
        ("El asistente utiliza un modelo de lenguaje para procesar las solicitudes del dueño.", .assistantMeta),
    ]

    @Test func lasCuatroMemoriasRealesSeRechazan() {
        for (content, reason) in Self.realGarbage {
            #expect(DistillGuard.reject(content, selfName: "Betty") == reason, "\(content)")
        }
    }

    @Test func hechosLegitimosPasan() {
        let facts = [
            "El dueño llama Betty a su asistente",
            "El dueño vive en Bogotá",
            "La hermana del dueño se llama Ana",
            "Cuando viaja, el dueño prefiere silla de ventana",
            "El dueño viaja a Lima el 12 de noviembre",
            "Animales: el dueño tiene dos gatos",
        ]
        for fact in facts {
            #expect(DistillGuard.reject(fact, selfName: "Betty",
                                        sourceTurns: ["Me voy a Lima el 12 de noviembre, anótalo"]) == nil, "\(fact)")
        }
    }

    @Test func interrogativosYVocativos() {
        #expect(DistillGuard.isQuestion("¿Dónde queda la oficina"))
        #expect(DistillGuard.isQuestion("Cómo funcionas"))
        #expect(DistillGuard.isQuestion("como funcionas"))
        #expect(DistillGuard.isQuestion("Puedes agendarme algo mañana"))
        #expect(DistillGuard.isQuestion("Oye, dime la hora"))
        #expect(!DistillGuard.isQuestion("El dueño pregunta mucho por su agenda"))
        #expect(!DistillGuard.isQuestion(""))
    }

    @Test func sujetoAsistenteONombreDelSelf() {
        #expect(DistillGuard.isAssistantMeta("Anima puede leer el calendario", selfName: nil))
        #expect(DistillGuard.isAssistantMeta("Betty usa Claude como modelo", selfName: "Betty"))
        #expect(DistillGuard.isAssistantMeta("La IA responde en español", selfName: nil))
        #expect(!DistillGuard.isAssistantMeta("Betty es la mamá del dueño", selfName: "Iris"))
        #expect(!DistillGuard.isAssistantMeta("El dueño llama Betty a su asistente", selfName: "Betty"))
    }

    @Test func ecoLiteralDeUnTurno() {
        let turns = ["Mañana tengo cita con el dentista a las 3pm", "hola"]
        #expect(DistillGuard.reject("mañana tengo cita con el dentista a las 3 pm", sourceTurns: turns) == .echo)
        #expect(DistillGuard.reject("El dueño tiene cita con el dentista", sourceTurns: turns) == nil)
        #expect(DistillGuard.similarity("abc", "abc") == 1)
        #expect(DistillGuard.similarity("", "abc") == 0)
    }

    // MARK: Integración con el ciclo

    static func cycle(distill: String, reflection: String = #"{"summary":"x","insights":[]}"#,
                      inbox: [String]) async throws -> (Consolidator.CycleReport, Brain, DatabaseQueue) {
        let queue = try AnimaDatabase.temporary()
        let brain = Brain(queue: queue, embedder: Embedder(forceFallback: true))
        let selfModel = SelfModel(queue: queue)
        await selfModel.seed(from: Birth(name: "Betty", tone: "x", language: "es"))
        let consolidator = Consolidator(brain: brain, queue: queue,
                                        provider: ScriptedProvider([.text(distill), .text(reflection)]),
                                        router: try .haikuAll(), authMode: .apiKey, token: "sk-ant-api03-x",
                                        selfModel: selfModel)
        let inboxStore = ConsolidationInbox(queue: queue)
        for text in inbox { try inboxStore.enqueue(sessionId: "s1", text: text) }
        return (try await consolidator.cycle(), brain, queue)
    }

    @Test func elCicloRechazaBasuraYLaAuditaEnElCycleLog() async throws {
        let distill = """
            [{"content":"Que tengo pendiente en mi agenda?","kind":"semantic","importance":8},
             {"content":"Betty cuéntame sobre cómo funcionas","kind":"semantic","importance":10},
             {"content":"El dueño llama Betty a su asistente","kind":"semantic","importance":7}]
            """
        let reflection = #"{"summary":"s","insights":["El asistente utiliza un modelo de lenguaje para procesar","El dueño valora respuestas cortas"]}"#
        let (report, brain, queue) = try await Self.cycle(
            distill: distill, reflection: reflection,
            inbox: ["Que tengo pendiente en mi agenda?", "Betty cuéntame sobre cómo funcionas"])
        let contents = try await brain.browse().filter(\.isValid).map(\.content)
        #expect(contents.contains("El dueño llama Betty a su asistente"))
        #expect(contents.contains("El dueño valora respuestas cortas"))
        #expect(!contents.contains { $0.contains("agenda?") || $0.contains("cuéntame") || $0.hasPrefix("El asistente") })
        #expect(report.added == 1)
        #expect(report.rejected == 3)
        let log = try #require(try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT report_json FROM cycle_log WHERE cycle=?", arguments: [report.cycle])
        })
        #expect(log.contains("pregunta del due"))
        #expect(log.contains("meta del asistente"))
    }

    @Test func listaVaciaEsExito() async throws {
        let (report, brain, _) = try await Self.cycle(distill: "[]", inbox: ["hola!"])
        #expect(report.completed)
        #expect(report.added == 0 && report.rejected == 0)
        #expect(try await brain.browse().isEmpty)
    }

    // MARK: Migración de limpieza

    @Test func laMigracionInvalidaLasExistentesUnaVez() async throws {
        let queue = try AnimaDatabase.temporary()
        let brain = Brain(queue: queue, embedder: Embedder(forceFallback: true))
        var ids: [String: MemoryID] = [:]
        for (content, _) in Self.realGarbage {
            ids[content] = try await brain.add(MemoryCandidate(content: content, kind: .semantic, importance: 9, source: "cycle:1"))
        }
        let legit = try await brain.add(MemoryCandidate(content: "El dueño llama Betty a su asistente",
                                                        kind: .semantic, importance: 7, source: "cycle:1"))
        let lesson = try await brain.add(MemoryCandidate(content: "Lección: la tool 'calendar' falla",
                                                         kind: .lesson, importance: 7, source: "real:x"))
        #expect(try await DistillMigration.runIfNeeded(queue: queue, brain: brain, selfName: "Betty") == 4)
        for id in ids.values {
            let record = try #require(try await brain.record(id))
            #expect(!record.isValid)
            #expect(record.invalidationReason == DistillGuard.migrationReason)
        }
        #expect(try await brain.record(legit)?.isValid == true)
        #expect(try await brain.record(lesson)?.isValid == true)
        // Idempotente: una nueva basura después de la migración no la re-corre.
        _ = try await brain.add(MemoryCandidate(content: "Que hora es?", kind: .semantic, importance: 5, source: "x"))
        #expect(try await DistillMigration.runIfNeeded(queue: queue, brain: brain, selfName: "Betty") == 0)
    }

    @Test func elPromptV2TieneCriteriosYNegativos() {
        let prompt = Consolidator.distillPrompt
        #expect(prompt.contains("PROHIBIDO"))
        #expect(prompt.contains("Que modelo usas para responder?"))
        #expect(prompt.contains("El dueño llama Betty a su asistente"))
        #expect(prompt.contains("devuelve []"))
    }
}

extension DistillGuardTests {
    @Test func elVocativoNoConvierteHechosEnPreguntas() {
        #expect(DistillGuard.reject("Trabaja como arquitecto de plataformas") == nil)
        #expect(DistillGuard.reject("Joshua cuando puede corre en la mañana") == nil)
    }
}
