import Foundation
import Testing
@testable import AnimaKit

// MARK: - Inyección en el assemble (§5.1 posición 6)

@Suite struct SkillInjectionTests {
    private func makeStore() throws -> (SymbolicStore, SessionID) {
        let store = SymbolicStore(queue: try AnimaDatabase.temporary())
        return (store, try store.startSession())
    }

    private var skill: Skill { SkillEngine.parse(SkillFixtures.agendar)! }

    @Test func skillBlockGoesInActivatedPositionAfterMemories() async throws {
        let (store, sid) = try makeStore()
        let wm = WorkingMemory(store: store)
        await wm.setActivatedMemories([
            ActivatedMemory(id: "m1", content: "Ana es la jefa de producto", kind: .semantic, confidence: 0.8, score: 0.1),
        ])
        await wm.setActivatedSkill(skill)
        let messages = try await wm.assemble(.text("agenda con Ana", sessionId: sid))

        // [system(self), user(activado: memorias + skill), user(turn)].
        #expect(messages.map(\.role) == [.system, .user, .user])
        let activated = messages[1].content
        #expect(activated.count == 2)
        guard case .text(let memories) = activated[0], case .text(let block) = activated[1] else {
            Issue.record("bloques activados ausentes"); return
        }
        #expect(memories.hasPrefix(WorkingMemory.activatedMemoriesHeader))
        #expect(block.hasPrefix("[SKILL: agendar-con-contexto — conocimiento aprendido, sigue estos pasos si aplican]"))
        #expect(block.contains("1. calendar.list(days_ahead=7)"))
        #expect(block.contains("Notas:\nRevisa conflictos"))
        #expect(messages.last?.content == [.text("agenda con Ana")])
    }

    @Test func skillAloneStillUsesActivatedPosition() async throws {
        let (store, sid) = try makeStore()
        try store.append(sessionId: sid, message: .user("hola"))
        try store.append(sessionId: sid, message: .assistant([.text("hola")]))
        let wm = WorkingMemory(store: store)
        await wm.setActivatedSkill(skill)
        let messages = try await wm.assemble(.text("agenda algo", sessionId: sid))
        #expect(messages.map(\.role) == [.user, .assistant, .system, .user, .user])
        guard case .text(let block)? = messages[3].content.first else { Issue.record("skill ausente"); return }
        #expect(block.hasPrefix("[SKILL: agendar-con-contexto"))
    }

    /// Cero regresión: sin skill (o limpiado con nil) el assemble es idéntico al golden.
    @Test func noSkillLeavesAssembleIdentical() async throws {
        let (store, sid) = try makeStore()
        try store.append(sessionId: sid, message: .user("hola"))
        let baseline = try await WorkingMemory(store: store).assemble(.text("¿qué tengo?", sessionId: sid))
        let wm = WorkingMemory(store: store)
        await wm.setActivatedSkill(skill)
        await wm.setActivatedSkill(nil)
        let messages = try await wm.assemble(.text("¿qué tengo?", sessionId: sid))
        #expect(messages == baseline)
        #expect(messages.map(\.role) == [.user, .system, .user])
    }

    @Test func onDeviceTruncatesToProfileBudget() async throws {
        let (store, _) = try makeStore()
        var long = skill
        long.body = String(repeating: "Revisa bien cada conflicto de horario. ", count: 80)
        let wm = WorkingMemory(store: store, profile: .onDevice)
        let injection = try #require(await wm.setActivatedSkill(long))
        #expect(injection.truncated)
        #expect(injection.text.count <= ContextProfile.onDevice.maxSkillChars)
        #expect(injection.text.hasSuffix(SkillInjection.truncationMarker))
        #expect(injection.text.hasPrefix(SkillInjection.header("agendar-con-contexto")))
        // Los pasos van antes que las notas: sobreviven al recorte.
        #expect(injection.text.contains("2. calendar.create"))

        let claude = SkillInjection.render(long, budgetChars: ContextProfile.claude.maxSkillChars)
        #expect(!claude.truncated)
    }

    @Test func tinyBudgetKeepsHeader() {
        let injection = SkillInjection.render(skill, budgetChars: 1)
        #expect(injection.truncated)
        #expect(injection.text.hasPrefix(SkillInjection.header("agendar-con-contexto")))
    }

    @Test func renderUsesDescriptionWhenNoWhen() {
        let s = Skill(name: "x", when: "", steps: [], description: "hace x")
        #expect(SkillInjection.render(s, budgetChars: 500).text == "[SKILL: x — conocimiento aprendido, sigue estos pasos si aplican]\nCuándo: hace x")
    }
}

@Suite struct SkillTurnOutcomeTests {
    @Test func outcomeCriterion() {
        #expect(SkillTurn.outcome(end: .finished(.endTurn), skillToolFailed: false) == .success)
        #expect(SkillTurn.outcome(end: .finished(.endTurn), skillToolFailed: true) == .failure)
        #expect(SkillTurn.outcome(end: .stopped(.loopDetected), skillToolFailed: false) == .failure)
        #expect(SkillTurn.outcome(end: .stopped(.maxIterations), skillToolFailed: false) == .failure)
        #expect(SkillTurn.outcome(end: .finished(.maxTokens), skillToolFailed: false) == .neutral)
        // Rechazo del dueño: neutral SIEMPRE, incluso con endTurn limpio.
        #expect(SkillTurn.outcome(end: .finished(.endTurn), skillToolFailed: false, ownerRejected: true) == .neutral)
        #expect(SkillTurn.outcome(end: .stopped(.maxIterations), skillToolFailed: false, ownerRejected: true) == .neutral)  // ni el stop posterior castiga
        #expect(SkillTurn.outcome(end: .refused, skillToolFailed: false) == .neutral)
        #expect(SkillTurn.outcome(end: .error, skillToolFailed: false) == .neutral)
        #expect(SkillTurn.outcome(end: .error, skillToolFailed: true) == .failure)
    }

    @Test func turnEndLabels() {
        #expect(TurnEnd.finished(.endTurn).label == "endTurn")
        #expect(TurnEnd.finished(nil).label == "none")
        #expect(TurnEnd.stopped(.loopDetected).label == "stopped:loopDetected")
        #expect(TurnEnd.refused.label == "refused")
        #expect(TurnEnd.error.label == "error")
    }
}

// MARK: - El turno integrado (AgentLoop)

@Suite struct SkillLoopTests {
    struct Harness {
        let loop: AgentLoop
        let provider: CapturingProvider
        let engine: SkillEngine?
        let telemetry: Telemetry
        let sid: SessionID
    }

    private func harness(scripts: [[ProviderEvent]], withSkills: Bool = true,
                         stop: StopConditions = .init(), override: Provider? = nil) throws -> Harness {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let telemetry = Telemetry(queue: queue)
        let provider = CapturingProvider(scripts)
        let engine = withSkills ? SkillEngine(queue: queue, directory: try SkillFixtures.standard()) : nil
        let notesRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let loop = AgentLoop(
            provider: override ?? provider, store: store, telemetry: telemetry,
            router: ModelRouter(config: try TestConfig.providerConfig()),
            authMode: .apiKey, token: "sk-ant-api03-xyz",
            clientTools: [NotesTool(root: notesRoot)], serverTools: [],
            stopConditions: stop, retryPolicy: RetryPolicy(maxAttempts: 1),
            skillEngine: engine, sleep: { _ in })
        return Harness(loop: loop, provider: provider, engine: engine, telemetry: telemetry,
                       sid: try store.startSession())
    }

    private static func notesCall(_ input: String) -> [ProviderEvent] {
        [.messageStart(id: "m1", model: "claude-opus-4-8"),
         .toolUseStart(id: "toolu_1", name: "notes"),
         .toolUseInputDelta(input),
         .blockStop(index: 0),
         .messageDelta(stopReason: .toolUse, usage: Usage(inputTokens: 10, outputTokens: 5)),
         .messageStop]
    }

    private static let done: [ProviderEvent] = [
        .messageStart(id: "m2", model: "claude-opus-4-8"),
        .textDelta("Listo."),
        .blockStop(index: 0),
        .messageDelta(stopReason: .endTurn, usage: Usage(inputTokens: 10, outputTokens: 5)),
        .messageStop,
    ]

    private func run(_ h: Harness, _ text: String) async -> [LoopEvent] {
        var events: [LoopEvent] = []
        for await event in await h.loop.run(sessionId: h.sid, userText: text) { events.append(event) }
        return events
    }

    @Test func matchedSkillIsInjectedAndPracticedOnSuccess() async throws {
        let h = try harness(scripts: [Self.notesCall(#"{"action":"create","name":"diario","content":"hoy"}"#), Self.done])
        let events = await run(h, "apunta en la nota diaria que terminé")
        #expect(events.contains(.turnFinished(stopReason: .endTurn)))

        // El bloque [SKILL] va en el contexto activado: justo antes del turn input.
        let first = try #require(h.provider.captures.value.first).messages
        guard case .text(let block)? = first[first.count - 2].content.last else {
            Issue.record("skill no inyectado"); return
        }
        #expect(block.hasPrefix("[SKILL: nota-diaria"))
        #expect(first.last == .user("apunta en la nota diaria que terminé"))

        let stats = try #require(await h.engine?.stats("nota-diaria"))
        #expect(stats.totalSuccess == 1 && stats.successStreak == 1)
        let rows = try h.telemetry.skillTurns()
        #expect(rows.count == 1)
        #expect(rows[0].skillName == "nota-diaria")
        #expect(rows[0].outcome == "success")
        #expect(rows[0].endReason == "endTurn")
        #expect(rows[0].skillToolCalls == 1 && rows[0].skillToolErrors == 0)
        #expect(rows[0].injectedChars > 0 && !rows[0].truncated)
        #expect((rows[0].score ?? 0) >= SkillEngine.matchThreshold)
    }

    @Test func failingSkillToolRecordsFailure() async throws {
        let h = try harness(scripts: [Self.notesCall(#"{"action":"read","name":"no-existe"}"#), Self.done])
        _ = await run(h, "lee mi nota diaria")
        let stats = try #require(await h.engine?.stats("nota-diaria"))
        #expect(stats.totalFail == 1 && stats.totalSuccess == 0)
        let row = try #require(try h.telemetry.skillTurns().first)
        #expect(row.outcome == "failure")
        #expect(row.skillToolErrors == 1)
    }

    @Test func stoppedTurnRecordsFailure() async throws {
        let call = Self.notesCall(#"{"action":"list"}"#)
        let h = try harness(scripts: [call, call], stop: StopConditions(maxIterations: 1))
        let events = await run(h, "revisa la nota diaria")
        #expect(events.contains(.stopped(.maxIterations)))
        #expect(await h.engine?.stats("nota-diaria")?.totalFail == 1)
        #expect(try h.telemetry.skillTurns().first?.endReason == "stopped:maxIterations")
    }

    @Test func providerErrorIsNeutral() async throws {
        let h = try harness(scripts: [], override: FailingProvider(error: ClassifiedError.fatal(status: 500, message: "boom")))
        _ = await run(h, "apunta en la nota diaria")
        #expect(await h.engine?.stats("nota-diaria") == nil)   // no se tocaron contadores
        let row = try #require(try h.telemetry.skillTurns().first)
        #expect(row.outcome == "neutral")
        #expect(row.endReason == "error")
    }

    /// Cero regresión: un turno sin match ensambla EXACTAMENTE lo mismo que un
    /// loop sin SkillEngine, y la telemetría registra el turno sin skill.
    @Test func turnWithoutMatchIsIdenticalToNoSkills() async throws {
        let with = try harness(scripts: [Self.done])
        let without = try harness(scripts: [Self.done], withSkills: false)
        _ = await run(with, "cuál es la capital de Francia")
        _ = await run(without, "cuál es la capital de Francia")
        let a = try #require(with.provider.captures.value.first).messages
        let b = try #require(without.provider.captures.value.first).messages
        #expect(a == b)
        #expect(a.map(\.role) == [.system, .user])

        let row = try #require(try with.telemetry.skillTurns().first)
        #expect(row.skillName == nil && row.outcome == "none" && row.injectedChars == 0)
        #expect(try without.telemetry.skillTurns().isEmpty)
    }
}
