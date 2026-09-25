import Foundation
import GRDB
import Testing
@testable import AnimaKit

/// Tool `reminders` falsa que se declara eferente AUN en list: la policy pide
/// ask ⇒ el runner aborta sin castigo y jamás la ejecuta.
final class MisdeclaredReminders: SensorimotorTool, @unchecked Sendable {
    let executed = Locked(false)
    var spec: ToolSpec {
        .client(name: "reminders", description: "r", inputSchema: .object(["type": .string("object")]))
    }
    func kind(for input: JSONValue) -> ToolKind { .efferent }
    func execute(_ input: JSONValue) async -> ToolResult {
        executed.mutate { $0 = true }
        return ToolResult(content: "no debió correr")
    }
}

@Suite struct SkillAutomationLoopTests {
    static let clockNow = Date(timeIntervalSince1970: 1_790_262_000)

    static func skill(steps: [String], name: String = "nota-diaria",
                      requires: String = "notes") -> String {
        """
        ---
        name: \(name)
        when: nota diaria, apunta en el diario, bitácora
        requires_tools: [\(requires)]
        steps:
        \(steps.map { "  - \($0)" }.joined(separator: "\n"))
        ---
        Una sola nota por día.
        """
    }

    static let standardSteps = ["notes.list()", "notes.read(name=diario-{hoy})?",
                                "notes.append(name=diario-{hoy}, content)"]

    struct Harness {
        let loop: AgentLoop
        let provider: CapturingProvider
        let engine: SkillEngine
        let telemetry: Telemetry
        let queue: DatabaseQueue
        let notesRoot: URL
        let sid: SessionID
    }

    private func harness(steps: [String] = standardSteps, streak: Int = 5,
                         extraTools: [any SensorimotorTool] = [], requires: String = "notes",
                         scripts: [[ProviderEvent]] = [done]) async throws -> Harness {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let telemetry = Telemetry(queue: queue)
        let provider = CapturingProvider(scripts)
        let dir = try SkillFixtures.dir(["nota.md": Self.skill(steps: steps, requires: requires)])
        let engine = SkillEngine(queue: queue, directory: dir, now: { Self.clockNow })
        for _ in 0..<streak { await engine.practice("nota-diaria", outcome: .success) }
        let notesRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: notesRoot, withIntermediateDirectories: true)
        let loop = AgentLoop(
            provider: provider, store: store, telemetry: telemetry,
            router: ModelRouter(config: try TestConfig.providerConfig()),
            authMode: .apiKey, token: "sk-ant-api03-xyz",
            clientTools: [NotesTool(root: notesRoot)] + extraTools, serverTools: [],
            retryPolicy: RetryPolicy(maxAttempts: 1),
            realRegister: RealRegister(queue: queue),
            skillEngine: engine, sleep: { _ in })
        return Harness(loop: loop, provider: provider, engine: engine, telemetry: telemetry,
                       queue: queue, notesRoot: notesRoot, sid: try store.startSession())
    }

    static let done: [ProviderEvent] = [
        .messageStart(id: "m1", model: "claude-opus-4-8"),
        .textDelta("Anotado."),
        .blockStop(index: 0),
        .messageDelta(stopReason: .endTurn, usage: Usage(inputTokens: 10, outputTokens: 5)),
        .messageStop,
    ]

    private func run(_ h: Harness, _ text: String) async -> [LoopEvent] {
        var events: [LoopEvent] = []
        for await event in await h.loop.run(sessionId: h.sid, userText: text) { events.append(event) }
        return events
    }

    /// El bloque activado (penúltimo mensaje) del primer request al provider.
    private func activatedBlock(_ h: Harness) -> String? {
        guard let messages = h.provider.captures.value.first?.messages, messages.count >= 2,
              case .text(let block)? = messages[messages.count - 2].content.last else { return nil }
        return block
    }

    private var today: String { SkillRunContext(turnText: "", now: Self.clockNow).today }

    // MARK: - Runner en el turno

    @Test func automatizedSkillRunsAfferentsAndCallsLLMOnce() async throws {
        let h = try await harness()
        let note = h.notesRoot.appendingPathComponent("diario-\(today).txt")
        try "08:00 café".write(to: note, atomically: true, encoding: .utf8)
        let turn = "apunta en la nota diaria que terminé el informe"
        let score = try #require(await h.engine.bestMatch(turn)?.score)
        #expect(score >= SkillEngine.automationThreshold)

        let events = await run(h, turn)
        #expect(events.contains(.turnFinished(stopReason: .endTurn)))
        #expect(h.provider.captures.value.count == 1)                 // el LLM, UNA vez

        let summary = try #require(events.compactMap { event -> SkillAutomationSummary? in
            if case .skillAutomated(let s) = event { return s } else { return nil }
        }.first)
        #expect(summary.skillName == "nota-diaria")
        #expect(summary.steps.map(\.step) == ["notes.list()", "notes.read(name=diario-\(today))?"])
        #expect(summary.pending == ["notes.append(name=diario-\(today), content)"])

        let block = try #require(activatedBlock(h))
        #expect(block.hasPrefix("[SKILL AUTOMATIZADA: nota-diaria — pasos ya ejecutados]"))
        #expect(block.contains("2. notes.read(name=diario-\(today))? → 08:00 café"))
        #expect(block.contains("Pendientes de tu confirmación"))
        // El eferente NUNCA se auto-ejecutó.
        #expect(try String(contentsOf: note, encoding: .utf8) == "08:00 café")

        let row = try #require(try h.telemetry.skillTurns().first)
        #expect(row.automatized && row.automatedSteps == 2 && row.automationAbort == nil)
        #expect(row.outcome == "success")
        #expect(row.injectedChars == block.count)
        #expect(await h.engine.stats("nota-diaria")?.successStreak == 6)
    }

    /// Practicada (racha 3) pero no automatizada ⇒ inyección normal, sin runner.
    @Test func practicedButNotAutomatizedInjectsKnowledge() async throws {
        let h = try await harness(streak: 3)
        let events = await run(h, "apunta en la nota diaria que terminé el informe")
        #expect(!events.contains { if case .skillAutomated = $0 { return true } else { return false } })
        #expect(activatedBlock(h)?.hasPrefix("[SKILL: nota-diaria — conocimiento aprendido") == true)
        let row = try #require(try h.telemetry.skillTurns().first)
        #expect(!row.automatized && row.automatedSteps == 0 && row.automationAbort == nil)
    }

    /// Automatizada pero el match no alcanza el umbral alto ⇒ solo sugiere.
    @Test func lowConfidenceMatchOnlyInjects() async throws {
        let h = try await harness()
        let turn = "bitácora del proyecto"
        let score = try #require(await h.engine.bestMatch(turn)?.score)
        #expect(score >= SkillEngine.matchThreshold && score < SkillEngine.automationThreshold)
        _ = await run(h, turn)
        #expect(activatedBlock(h)?.hasPrefix("[SKILL: nota-diaria") == true)
        #expect(try h.telemetry.skillTurns().first?.automatized == false)
    }

    /// Desautomatización (§B.6): un aferente falla ⇒ aborta el resto, cae a
    /// inyección EN EL MISMO TURNO, practice(.failure) y el fallo va al RealRegister.
    @Test func afferentFailureDeautomatizesAndFallsBackSameTurn() async throws {
        let h = try await harness(steps: ["notes.read(name=no-existe)", "notes.list()",
                                          "notes.append(name=x, content)"])
        let events = await run(h, "apunta en la nota diaria que terminé el informe")
        #expect(events.contains(.turnFinished(stopReason: .endTurn)))
        #expect(!events.contains { if case .skillAutomated = $0 { return true } else { return false } })
        #expect(h.provider.captures.value.count == 1)
        #expect(activatedBlock(h)?.hasPrefix("[SKILL: nota-diaria — conocimiento aprendido") == true)

        let stats = try #require(await h.engine.stats("nota-diaria"))
        #expect(stats.successStreak == 0 && stats.totalFail == 1 && stats.level == .learned)
        #expect(await h.engine.automatize("nota-diaria") == nil)

        let failures = try await h.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT tool_name, error_class, raw_error FROM real_failure")
        }
        #expect(failures.count == 1)
        #expect(failures.first?["tool_name"] == "notes")
        let raw: String = try #require(failures.first?["raw_error"])
        #expect(raw.contains("no existe"))
        // Misma taxonomía que un fallo de tool del flujo normal.
        #expect(failures.first?["error_class"] == PatternKey.errorClass(fromToolResult: raw))

        let row = try #require(try h.telemetry.skillTurns().first)
        #expect(row.automatized && row.automationAbort == "step_failed" && row.automatedSteps == 0)
        #expect(row.outcome == "failure")
        // Cada nota del sandbox sigue intacta: no hubo escrituras.
        #expect((try FileManager.default.contentsOfDirectory(atPath: h.notesRoot.path)).isEmpty)
    }

    /// Placeholder irresoluble ⇒ abort SIN castigo; el turno sigue por inyección
    /// y su desenlace practica normalmente.
    @Test func unresolvedPlaceholderAbortsWithoutPunishment() async throws {
        let h = try await harness(steps: ["notes.read(name=diario-{ayer})"])
        _ = await run(h, "apunta en la nota diaria que terminé el informe")
        #expect(activatedBlock(h)?.hasPrefix("[SKILL: nota-diaria") == true)
        let row = try #require(try h.telemetry.skillTurns().first)
        #expect(row.automatized && row.automationAbort == "unresolved_arg")
        #expect(row.outcome == "success")
        #expect(await h.engine.stats("nota-diaria")?.successStreak == 6)
        let failures = try await h.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM real_failure") }
        #expect(failures == 0)
    }

    /// Los invariantes no se delegan: si la policy pide ask para un paso "aferente",
    /// el runner no ejecuta ni pregunta — aborta neutral.
    @Test func policyAskAbortsNeutralWithoutExecuting() async throws {
        let spy = MisdeclaredReminders()
        let h = try await harness(steps: ["reminders.list()"], extraTools: [spy])
        _ = await run(h, "apunta en la nota diaria que terminé el informe")
        #expect(spy.executed.value == false)
        let row = try #require(try h.telemetry.skillTurns().first)
        #expect(row.automationAbort == "policy_ask")
        #expect(await h.engine.stats("nota-diaria")?.totalFail == 0)
    }

    /// Golden: un turno sin match con una skill automatizada cargada ensambla
    /// EXACTAMENTE lo mismo que un loop sin SkillEngine.
    @Test func noMatchTurnIsIdenticalEvenWithAutomatizedSkill() async throws {
        let h = try await harness()
        _ = await run(h, "cuál es la capital de Francia")
        let messages = try #require(h.provider.captures.value.first).messages
        #expect(messages.map(\.role) == [.system, .user])
        #expect(messages.last == .user("cuál es la capital de Francia"))
        let row = try #require(try h.telemetry.skillTurns().first)
        #expect(row.skillName == nil && !row.automatized)
    }
}
