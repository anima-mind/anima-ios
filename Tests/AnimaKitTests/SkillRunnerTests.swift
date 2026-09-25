import Foundation
import Testing
@testable import AnimaKit

// 2026-09-24 15:00 UTC — {hoy} determinístico en UTC.
private let fixedNow = Date(timeIntervalSince1970: 1_790_262_000)
private let utc = TimeZone(identifier: "UTC")!
private func ctx(_ turn: String = "apunta en la nota diaria") -> SkillRunContext {
    SkillRunContext(turnText: turn, now: fixedNow, timeZone: utc)
}

/// Confirmación espía: registra si alguien intentó pedir ok al dueño.
final class SpyConfirmation: ConfirmationProvider, @unchecked Sendable {
    let asked = Locked(0)
    func confirm(_ request: ConfirmationRequest) async -> Bool {
        asked.mutate { $0 += 1 }
        return true
    }
}

// MARK: - Gramática de pasos

@Suite struct SkillStepGrammarTests {
    @Test func resolvesFixedArgsTypedWithAction() throws {
        let call = try SkillStep.resolve("calendar.list(days_ahead=7)", context: ctx()).get()
        #expect(call.tool == "calendar" && call.operation == "list")
        #expect(call.input == .object(["action": .string("list"), "days_ahead": .int(7)]))
        #expect(!call.optional)
        #expect(call.display == "calendar.list(days_ahead=7)")

        let flags = try SkillStep.resolve(#"x.y(a=true, b=false, c="hola mundo", d='q')"#, context: ctx()).get()
        #expect(flags.input == .object(["action": .string("y"), "a": .bool(true), "b": .bool(false),
                                        "c": .string("hola mundo"), "d": .string("q")]))
        let bare = try SkillStep.resolve("notes.list", context: ctx()).get()
        #expect(bare.input == .object(["action": .string("list")]))
        #expect(try SkillStep.resolve("reminders.list()", context: ctx()).get().input == .object(["action": .string("list")]))
    }

    @Test func interpolatesHoyAndTurno() throws {
        #expect(ctx().today == "2026-09-24")
        let read = try SkillStep.resolve("notes.read(name=diario-{hoy})?", context: ctx()).get()
        #expect(read.optional)
        #expect(read.input["name"] == .string("diario-2026-09-24"))
        #expect(read.display == "notes.read(name=diario-2026-09-24)?")

        let search = try SkillStep.resolve("calendar.search(query={turno})", context: ctx("  Ana  ")).get()
        #expect(search.input["query"] == .string("Ana"))
        // Un número interpolado NO se tipa: viene de un placeholder, es texto.
        let n = try SkillStep.resolve("x.y(n={turno})", context: ctx("42")).get()
        #expect(n.input["n"] == .string("42"))
    }

    @Test func unresolvableArgumentsAbort() {
        let unresolved: [String] = [
            "notes.append(name=diario-{hoy}, content)",           // clave sin valor
            "calendar.search(query=<título o persona>)",           // lo decide el LLM
            "notes.read(name={ayer})",                             // placeholder desconocido
            "notes.read(name={hoy)",                               // placeholder sin cerrar
            "calendar.list(action=create)",                        // no se pisa la operación
            "notes.read(=x)",
        ]
        for step in unresolved {
            guard case .failure(.unresolvedArgument) = SkillStep.resolve(step, context: ctx()) else {
                Issue.record("debió abortar: \(step)"); continue
            }
        }
        // {turno} vacío no es determinístico.
        guard case .failure(.unresolvedArgument) = SkillStep.resolve("x.y(q={turno})", context: ctx("   ")) else {
            Issue.record("turno vacío debió abortar"); return
        }
        #expect(SkillStep.resolve("revisa la agenda", context: ctx()) == .failure(.notACall(step: "revisa la agenda")))
        #expect(SkillStep.resolve("notes.read(name=x", context: ctx()) == .failure(.notACall(step: "notes.read(name=x")))
    }

    @Test func lenientInterpolationKeepsUnknown() {
        #expect(SkillStep.interpolate("a-{hoy}-{x}-{turno}", context: ctx("t")) == "a-2026-09-24-{x}-t")
        #expect(SkillStep.interpolate("abierto {hoy", context: ctx()) == "abierto {hoy")
        #expect(SkillStep.interpolate("abierto {hoy", context: ctx(), strict: true) == nil)
    }
}

// MARK: - Runner

@Suite struct SkillRunnerTests {
    private static let notaSkill = Skill(
        name: "nota-diaria", when: "nota diaria",
        steps: ["notes.list()", "notes.read(name=diario-{hoy})?", "notes.append(name=diario-{hoy}, content)"],
        body: "Una sola nota por día.")

    private func compiled(_ skill: Skill) -> CompiledSkill {
        CompiledSkill(name: skill.name,
                      afferentSteps: skill.steps.filter { !SkillEngine.isEfferent(step: $0) },
                      efferentSteps: skill.steps.filter { SkillEngine.isEfferent(step: $0) },
                      skill: skill)
    }

    private func sandbox() throws -> (Sensorimotor, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (Sensorimotor(tools: [NotesTool(root: root)], confirmation: FailClosedConfirmation()), root)
    }

    /// Aferentes reales (NotesTool sandbox) sin LLM; el eferente queda pendiente
    /// y la nota NO se toca.
    @Test func runsAfferentsAndComposesBlock() async throws {
        let (sm, root) = try sandbox()
        let note = root.appendingPathComponent("diario-2026-09-24.txt")
        try "09:00 arranqué".write(to: note, atomically: true, encoding: .utf8)
        let run = await SkillRunner.run(compiled(Self.notaSkill), context: ctx(), availableTools: ["notes"]) {
            await sm.executePreauthorized(name: $0, input: $1)
        }
        #expect(run.completed)
        #expect(run.executed.map(\.step) == ["notes.list()", "notes.read(name=diario-2026-09-24)?"])
        #expect(run.executed[0].result == "diario-2026-09-24.txt")
        #expect(run.executed[1].result == "09:00 arranqué" && !run.executed[1].isError)
        #expect(run.pendingEfferent == ["notes.append(name=diario-2026-09-24, content)"])
        #expect(try String(contentsOf: note, encoding: .utf8) == "09:00 arranqué")   // eferente jamás corrió

        let block = run.injection(for: Self.notaSkill, budgetChars: 6000)
        #expect(!block.truncated)
        #expect(block.text == """
            [SKILL AUTOMATIZADA: nota-diaria — pasos ya ejecutados]
            Cuándo: nota diaria
            Pasos ejecutados (ya corridos: no los repitas):
            1. notes.list() → diario-2026-09-24.txt
            2. notes.read(name=diario-2026-09-24)? → 09:00 arranqué
            Pendientes de tu confirmación (eferentes, NO ejecutados — propónlos por el flujo normal solo si aplican):
            - notes.append(name=diario-2026-09-24, content)
            Notas:
            Una sola nota por día.
            """)
        #expect(run.summary == SkillAutomationSummary(skillName: "nota-diaria", steps: run.executed,
                                                      pending: run.pendingEfferent))
    }

    /// Paso opcional que falla (la nota de hoy aún no existe): se anota y sigue.
    @Test func optionalStepFailureContinues() async throws {
        let (sm, _) = try sandbox()
        let run = await SkillRunner.run(compiled(Self.notaSkill), context: ctx(), availableTools: ["notes"]) {
            await sm.executePreauthorized(name: $0, input: $1)
        }
        #expect(run.completed)
        #expect(run.executed.count == 2 && run.executed[1].isError)
        #expect(run.injection(for: Self.notaSkill, budgetChars: 6000).text
            .contains("2. notes.read(name=diario-2026-09-24)? → (sin resultado) La nota 'diario-2026-09-24' no existe."))
    }

    /// Fallo de un aferente obligatorio: aborta el resto y castiga.
    @Test func afferentFailureAbortsRest() async throws {
        let skill = Skill(name: "s", when: "", steps: ["notes.read(name=no-existe)", "notes.list()"])
        let calls = Locked(0)
        let (sm, _) = try sandbox()
        let run = await SkillRunner.run(compiled(skill), context: ctx(), availableTools: ["notes"]) {
            calls.mutate { $0 += 1 }
            return await sm.executePreauthorized(name: $0, input: $1)
        }
        #expect(run.abort == .stepFailed && run.abort?.punishes == true)
        #expect(calls.value == 1)                        // notes.list nunca corrió
        #expect(run.failedCall?.step == "notes.read(name=no-existe)")
        #expect(run.failedResult?.isError == true)
        #expect(run.executed.isEmpty)
    }

    /// Arg irresoluble: aborta ANTES de ejecutar nada (sin efectos, sin castigo).
    @Test func unresolvedArgumentAbortsBeforeExecuting() async {
        let skill = Skill(name: "agendar", when: "",
                          steps: ["calendar.list(days_ahead=7)", "calendar.search(query=<título>)", "calendar.create(title)"])
        let calls = Locked(0)
        let run = await SkillRunner.run(compiled(skill), context: ctx(), availableTools: ["calendar"]) { _, _ in
            calls.mutate { $0 += 1 }
            return .executed(ToolResult(content: "ok"))
        }
        #expect(run.abort == .unresolvedArgument && run.abort?.punishes == false)
        #expect(calls.value == 0)
    }

    @Test func policyAskIsNeutralDenyPunishes() async {
        let skill = Skill(name: "s", when: "", steps: ["calendar.list(days_ahead=1)"])
        let ask = await SkillRunner.run(compiled(skill), context: ctx(), availableTools: ["calendar"]) { tool, input in
            .needsConfirmation(ConfirmationRequest(tool: tool, operation: "list", summary: "x", input: input))
        }
        #expect(ask.abort == .policyAsk && ask.abort?.punishes == false && ask.failedCall == nil)
        let deny = await SkillRunner.run(compiled(skill), context: ctx(), availableTools: ["calendar"]) { _, _ in
            .denied(ToolResult(content: "Acción no permitida por la política de permisos.", isError: true))
        }
        #expect(deny.abort == .policyDenied && deny.abort?.punishes == true)
        #expect(deny.failedCall?.tool == "calendar")
    }

    @Test func unavailableToolOrNothingToRunIsNeutral() async {
        let skill = Skill(name: "s", when: "", steps: ["reminders.list()"])
        let run = await SkillRunner.run(compiled(skill), context: ctx(), availableTools: ["notes"]) { _, _ in
            .executed(ToolResult(content: "no debería"))
        }
        #expect(run.abort == .toolUnavailable && !(run.abort?.punishes ?? true))
        let onlyWrites = Skill(name: "w", when: "", steps: ["notes.create(name=x, content)"])
        let none = await SkillRunner.run(compiled(onlyWrites), context: ctx(), availableTools: ["notes"]) { _, _ in
            .executed(ToolResult(content: "no debería"))
        }
        #expect(none.abort == .noAfferentSteps)
        #expect(none.pendingEfferent == ["notes.create(name=x, content)"])
    }

    @Test func longResultsAreClippedAndBlockBudgeted() async {
        let skill = Skill(name: "s", when: "", steps: ["notes.list()"], description: "hace s")
        let long = String(repeating: "x", count: 5000)
        let run = await SkillRunner.run(compiled(skill), context: ctx(), availableTools: ["notes"]) { _, _ in
            .executed(ToolResult(content: long))
        }
        let full = run.injection(for: skill, budgetChars: 100_000)
        #expect(full.text.contains("…[recortado]"))
        #expect(full.text.contains("Cuándo: hace s"))
        #expect(full.text.count < SkillRun.maxResultChars + 200)
        let tiny = run.injection(for: skill, budgetChars: 120)
        #expect(tiny.truncated && tiny.text.count <= 120)
        #expect(tiny.text.hasPrefix(SkillRun.header("s")))
    }
}

// MARK: - Sensorimotor sin prompt (camino del runner)

@Suite struct SensorimotorPreauthorizedTests {
    @Test func efferentNeedsConfirmationWithoutAskingOwner() async {
        let spy = SpyEfferentTool()
        let confirmation = SpyConfirmation()
        let sm = Sensorimotor(tools: [spy], confirmation: confirmation)
        let outcome = await sm.executePreauthorized(name: "spy", input: .object([:]))
        guard case .needsConfirmation(let request) = outcome else { Issue.record("debió pedir ask"); return }
        #expect(request.tool == "spy" && request.operation == "write")
        #expect(spy.executed.value == false)
        #expect(confirmation.asked.value == 0)          // al dueño no se le preguntó nada

        // El camino normal sí pide ok (y con ok ejecuta).
        #expect(await sm.execute(name: "spy", input: .object([:])).isError == false)
        #expect(confirmation.asked.value == 1 && spy.executed.value)
    }

    @Test func unknownToolDeniedAndAllowlistExecutes() async {
        let sm = Sensorimotor(tools: [])
        guard case .denied(let result) = await sm.executePreauthorized(name: "ghost", input: .null) else {
            Issue.record("desconocida debió negarse"); return
        }
        #expect(result.isError)
        let spy = SpyEfferentTool()
        let allowed = Sensorimotor(tools: [spy], policy: PermissionPolicy(allowlist: [AllowlistEntry(tool: "spy", operation: "write")]))
        #expect(await allowed.executePreauthorized(name: "spy", input: .null) == .executed(ToolResult(content: "hecho")))
    }
}
