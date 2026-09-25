// SkillRunner.swift — la última milla del arco declarativo→procedural (§5.7,
// §B.6; Kandel: la práctica compila el conocimiento en procedimiento). Corre un
// CompiledSkill como System 1 con guardias de System 2:
//   · los pasos AFERENTES se ejecutan directo por el Sensorimotor (misma
//     PermissionPolicy: los invariantes no se delegan), sin LLM paso a paso;
//   · los EFERENTES jamás se auto-ejecutan: quedan "pendientes de tu
//     confirmación" en el bloque y el LLM los propone por el flujo normal;
//   · si algo no es determinístico (arg irresoluble) o la policy pide `ask`,
//     aborta SIN castigo y el turno cae a inyección de conocimiento;
//   · si un aferente falla (o la policy dice `deny`) aborta CON castigo: la
//     racha se rompe (desautomatización dirigida por lo Real, §B.6).

import Foundation

/// Por qué el runner no completó la automatización.
public enum AutomationAbort: String, Sendable, Equatable {
    case unresolvedArgument = "unresolved_arg"    // paso no determinístico
    case toolUnavailable = "tool_unavailable"     // la tool del paso no está registrada
    case noAfferentSteps = "no_afferent_steps"    // nada que correr solo
    case policyAsk = "policy_ask"                 // la policy pidió confirmación
    case policyDenied = "policy_denied"           // la policy negó
    case stepFailed = "step_failed"               // un aferente falló

    /// ¿Castiga la racha (practice .failure ⇒ deja de estar automatized)? Solo
    /// lo Real castiga: un fallo o un deny. Lo demás es abort neutral.
    public var punishes: Bool { self == .stepFailed || self == .policyDenied }
}

/// Un paso aferente ya corrido, con su resultado (para el bloque y la UI).
public struct AutomatedStep: Sendable, Equatable {
    public var step: String       // el paso con placeholders resueltos
    public var result: String
    public var isError: Bool      // solo en pasos opcionales ("?") que fallaron
}

/// Lo que la UI muestra: "⚡ <skill> ejecutó N pasos".
public struct SkillAutomationSummary: Sendable, Equatable {
    public var skillName: String
    public var steps: [AutomatedStep]
    public var pending: [String]
}

/// Resultado de correr un CompiledSkill.
public struct SkillRun: Sendable, Equatable {
    public var skillName: String
    public var executed: [AutomatedStep]
    public var pendingEfferent: [String]
    public var abort: AutomationAbort?
    /// El paso que falló (stepFailed/policyDenied) con su resultado: va al RealRegister.
    public var failedCall: SkillStepCall?
    public var failedResult: ToolResult?

    public var completed: Bool { abort == nil }
    public var summary: SkillAutomationSummary {
        SkillAutomationSummary(skillName: skillName, steps: executed, pending: pendingEfferent)
    }

    public static func header(_ name: String) -> String {
        "[SKILL AUTOMATIZADA: \(name) — pasos ya ejecutados]"
    }
    /// Recorte por resultado de paso (antes del presupuesto total del bloque).
    public static let maxResultChars = 1500

    /// El bloque de conocimiento del turno: pasos corridos con su resultado +
    /// eferentes pendientes + notas del skill, truncado a `budgetChars`.
    public func injection(for skill: Skill, budgetChars: Int) -> SkillInjection {
        var parts = [Self.header(skillName)]
        let trigger = skill.when.isEmpty ? skill.description : skill.when
        if !trigger.isEmpty { parts.append("Cuándo: \(trigger)") }
        if !executed.isEmpty {
            let lines = executed.enumerated().map { index, step in
                "\(index + 1). \(step.step) →\(step.isError ? " (sin resultado)" : "") \(Self.clip(step.result))"
            }
            parts.append("Pasos ejecutados (ya corridos: no los repitas):\n" + lines.joined(separator: "\n"))
        }
        if !pendingEfferent.isEmpty {
            parts.append("Pendientes de tu confirmación (eferentes, NO ejecutados — propónlos por el flujo normal solo si aplican):\n"
                         + pendingEfferent.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !skill.body.isEmpty { parts.append("Notas:\n" + skill.body) }
        return SkillInjection.truncated(name: skillName, header: Self.header(skillName),
                                        full: parts.joined(separator: "\n"), budgetChars: budgetChars)
    }

    private static func clip(_ text: String) -> String {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > maxResultChars else { return flat }
        return String(flat.prefix(maxResultChars)) + "…[recortado]"
    }
}

public enum SkillRunner {
    public typealias Executor = @Sendable (_ tool: String, _ input: JSONValue) async -> PreauthorizedExecution

    /// Corre los aferentes del compilado. Resuelve TODOS los pasos antes de
    /// ejecutar nada: un arg irresoluble aborta sin efectos laterales.
    public static func run(_ compiled: CompiledSkill, context: SkillRunContext,
                           availableTools: Set<String>, execute: Executor) async -> SkillRun {
        let pending = compiled.efferentSteps.map { SkillStep.interpolate($0, context: context) ?? $0 }
        var run = SkillRun(skillName: compiled.name, executed: [], pendingEfferent: pending, abort: nil)

        guard !compiled.afferentSteps.isEmpty else {
            run.abort = .noAfferentSteps
            return run
        }
        var calls: [SkillStepCall] = []
        for step in compiled.afferentSteps {
            guard case .success(let call) = SkillStep.resolve(step, context: context) else {
                run.abort = .unresolvedArgument
                return run
            }
            guard availableTools.contains(call.tool) else {
                run.abort = .toolUnavailable
                return run
            }
            calls.append(call)
        }

        for call in calls {
            switch await execute(call.tool, call.input) {
            case .executed(let result) where !result.isError:
                run.executed.append(AutomatedStep(step: call.display, result: result.content, isError: false))
            case .executed(let result) where call.optional:
                run.executed.append(AutomatedStep(step: call.display, result: result.content, isError: true))
            case .executed(let result):
                return aborted(run, .stepFailed, call, result)
            case .denied(let result):
                return aborted(run, .policyDenied, call, result)
            case .needsConfirmation:
                run.abort = .policyAsk
                return run
            }
        }
        return run
    }

    private static func aborted(_ run: SkillRun, _ reason: AutomationAbort,
                                _ call: SkillStepCall, _ result: ToolResult) -> SkillRun {
        var run = run
        run.abort = reason
        run.failedCall = call
        run.failedResult = result
        return run
    }
}
