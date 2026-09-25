// SkillEngine.swift — skills = CONOCIMIENTO procedural (§5.7, v1 mínimo; el spec
// marca que YA EXISTE), no capacidad (eso son las tools). Actor. Los skills son
// markdown portable con front-matter (name/description/when/steps/requires_tools)
// cargado de un dir sandbox `skills/` vía SkillStore (hot-reload por mtime).
// Arco declarativo→procedural: el AgentLoop INYECTA el skill que matchea como
// conocimiento al contexto activado del turno; al cerrar el turno lo practica.
//   bestMatch(_,_)    — el mejor skill por overlap léxico ponderado (0 LLM).
//   practice(_,_)     — contador de éxitos/fallos; ≥3 éxitos seguidos ⇒ practiced.
//   automatize(_)     — un skill practiced se compila a la secuencia de pasos
//                       aferentes ejecutable sin re-consultar al LLM paso a paso.
// Hook documentado: los pasos EFERENTES de un CompiledSkill SIEMPRE siguen pidiendo
// ok (nunca se automatiza una escritura); en v1 `practiced` es el estado terminal
// y el runner que ejecuta un CompiledSkill en el loop queda como extensión.

import Foundation
import GRDB

/// Un skill declarativo: CONOCIMIENTO procedural (cómo hacer algo) en markdown
/// portable — no una capacidad (eso son las tools). Front-matter del doc 05 §6.2
/// (`name`/`description`/`requires_tools`) + el de §5.7 (`when`/`steps`).
public struct Skill: Sendable, Equatable, Identifiable {
    public var name: String
    public var when: String       // descripción del gatillo (para el match)
    public var steps: [String]    // pasos en orden, p.ej. "calendar.list(days_ahead=1)"
    public var body: String       // prosa opcional tras el front-matter (notas)
    public var description: String
    /// Tools que el skill exige (doc 05): si falta alguna, el skill no matchea.
    public var requiresTools: [String]

    public var id: String { name }

    public init(name: String, when: String, steps: [String], body: String = "",
                description: String = "", requiresTools: [String] = []) {
        self.name = name
        self.when = when
        self.steps = steps
        self.body = body
        self.description = description
        self.requiresTools = requiresTools
    }

    /// Tools que el skill toca: las de sus pasos (`calendar.list(...)` → calendar)
    /// + las declaradas en `requires_tools`. Un fallo de cualquiera cuenta como
    /// fallo del skill en `practice`.
    public var toolNames: Set<String> {
        var names = Set(requiresTools)
        for step in steps {
            let end = step.firstIndex { $0 == "." || $0 == "(" } ?? step.endIndex
            let tool = step[..<end].trimmingCharacters(in: .whitespaces)
            if !tool.isEmpty { names.insert(tool) }
        }
        return names
    }
}

/// Resultado del match: el skill ganador con su score (para telemetría/eval).
public struct SkillMatch: Sendable, Equatable {
    public var skill: Skill
    public var score: Double
    public var overlap: Int
}

/// Desenlace de un turno con skill inyectado (§5.7 practice).
public enum SkillOutcome: String, Sendable, Equatable {
    case success    // cerró endTurn y ninguna tool del skill falló
    case failure    // falló una tool del skill o el turno se detuvo (stop condition)
    case neutral    // error del provider / refusal / max_tokens: no dice nada del skill
}

/// Estado del skill para la UI: learned (declarativo) → practiced.
public struct SkillOverview: Sendable, Equatable, Identifiable {
    public var name: String
    public var summary: String
    public var practiced: Bool
    public var totalSuccess: Int
    public var totalFail: Int
    public var successStreak: Int
    public var disabled: Bool
    public var id: String { name }
}

/// Bloque de conocimiento listo para el contexto activado del turno.
public struct SkillInjection: Sendable, Equatable {
    public var skillName: String
    public var text: String
    public var truncated: Bool

    public static func header(_ name: String) -> String {
        "[SKILL: \(name) — conocimiento aprendido, sigue estos pasos si aplican]"
    }
    public static let truncationMarker = "…[skill truncada]"

    /// Render del skill: header + gatillo + pasos + notas, truncado a `budgetChars`
    /// (los pasos van antes que las notas: si hay que cortar, se pierden notas).
    public static func render(_ skill: Skill, budgetChars: Int) -> SkillInjection {
        var parts = [header(skill.name)]
        let trigger = skill.when.isEmpty ? skill.description : skill.when
        if !trigger.isEmpty { parts.append("Cuándo: \(trigger)") }
        if !skill.steps.isEmpty {
            parts.append("Pasos:\n" + skill.steps.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n"))
        }
        if !skill.body.isEmpty { parts.append("Notas:\n" + skill.body) }
        let full = parts.joined(separator: "\n")
        let budget = max(budgetChars, header(skill.name).count + truncationMarker.count)
        guard full.count > budget else {
            return SkillInjection(skillName: skill.name, text: full, truncated: false)
        }
        let kept = String(full.prefix(budget - truncationMarker.count))
        return SkillInjection(skillName: skill.name, text: kept + truncationMarker, truncated: true)
    }
}

/// Un skill practiced compilado: sus pasos aferentes corren sin LLM paso a paso;
/// los eferentes se marcan aparte y SIEMPRE piden ok (§5.7).
public struct CompiledSkill: Sendable, Equatable {
    public var name: String
    public var afferentSteps: [String]
    public var efferentSteps: [String]
}

public struct SkillStats: Sendable, Equatable {
    public var name: String
    public var successStreak: Int
    public var totalSuccess: Int
    public var totalFail: Int
    public var practiced: Bool
}

public actor SkillEngine {
    private let queue: DatabaseQueue
    /// Lector del dir sandbox con hot-reload por mtime (nil ⇒ sin skills).
    public nonisolated let store: SkillStore?
    private let now: @Sendable () -> Date
    private let practiceThreshold: Int
    /// Score mínimo del match (overlap ponderado / min(|turno|, |gatillo|)).
    static let matchThreshold = 0.34
    /// Prefijos de tool considerados eferentes (escriben): nunca se automatizan.
    private static let efferentTools: Set<String> = ["calendar.create", "calendar.delete",
                                                      "reminders.create", "reminders.complete",
                                                      "notes.write", "notes.append"]

    public init(queue: DatabaseQueue, directory: URL? = nil,
                practiceThreshold: Int = 3,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(queue: queue, store: directory.map { SkillStore(directory: $0) },
                  practiceThreshold: practiceThreshold, now: now)
    }

    public init(queue: DatabaseQueue, store: SkillStore?,
                practiceThreshold: Int = 3,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.queue = queue
        self.store = store
        self.practiceThreshold = practiceThreshold
        self.now = now
    }

    // MARK: - Carga

    /// Los skills del dir sandbox (archivos *.md con front-matter). Sin dir
    /// o dir inexistente ⇒ vacío (el harness funciona sin skills).
    public func loadSkills() -> [Skill] {
        store?.skills() ?? []
    }

    // MARK: - match

    /// El mejor skill para un turno (0 LLM). Compat: sin filtro de tools.
    public func match(_ task: String) -> Skill? {
        bestMatch(task)?.skill
    }

    /// Match léxico determinista del texto del turno contra el gatillo de cada
    /// skill (`when` + `description` + `name`). Tokens normalizados (minúsculas,
    /// sin tildes, sin stopwords, stem por prefijo de 5 chars — "agenda",
    /// "agendar", "agéndame" colapsan). Cada token compartido pesa 1/df (df = en
    /// cuántos gatillos aparece) para que lo específico de un skill desempate lo
    /// genérico; score = Σpesos / min(|turno|, |gatillo|) ≥ 0.34. Excluye skills
    /// deshabilitados y los que exigen una tool ausente. Empates: score → overlap
    /// crudo → nombre (orden total, mismo input ⇒ mismo output).
    public func bestMatch(_ task: String, availableTools: Set<String>? = nil) -> SkillMatch? {
        let query = Self.tokens(task)
        guard !query.isEmpty else { return nil }
        let disabled = disabledNames()
        let candidates = loadSkills().filter { skill in
            guard !disabled.contains(skill.name) else { return false }
            guard let availableTools else { return true }
            return skill.requiresTools.allSatisfy { availableTools.contains($0) }
        }
        let triggers = candidates.map { Self.tokens($0.when + " " + $0.description + " " + $0.name) }
        var df: [String: Int] = [:]
        for trigger in triggers { for token in trigger { df[token, default: 0] += 1 } }

        var best: SkillMatch?
        for (skill, trigger) in zip(candidates, triggers) where !trigger.isEmpty {
            let shared = query.intersection(trigger)
            guard !shared.isEmpty else { continue }
            let weight = shared.reduce(0.0) { $0 + 1.0 / Double(df[$1] ?? 1) }
            let score = weight / Double(min(query.count, trigger.count))
            guard score >= Self.matchThreshold else { continue }
            let candidate = SkillMatch(skill: skill, score: score, overlap: shared.count)
            if let current = best {
                if (score, shared.count, current.skill.name) > (current.score, current.overlap, skill.name) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }
        return best
    }

    // MARK: - Estado para la UI

    /// Deshabilita (o rehabilita) un skill: deshabilitado no matchea nunca.
    public func setDisabled(_ name: String, _ disabled: Bool) {
        let ts = now().timeIntervalSince1970
        try? queue.write { db in
            try db.execute(sql: """
                INSERT INTO skill_practice (skill_name, disabled, updated_at) VALUES (?,?,?)
                ON CONFLICT(skill_name) DO UPDATE SET disabled=excluded.disabled, updated_at=excluded.updated_at
                """, arguments: [name, disabled ? 1 : 0, ts])
        }
    }

    public func isDisabled(_ name: String) -> Bool {
        disabledNames().contains(name)
    }

    private func disabledNames() -> Set<String> {
        Set((try? queue.read { db in
            try String.fetchAll(db, sql: "SELECT skill_name FROM skill_practice WHERE disabled=1")
        }) ?? [])
    }

    /// Lista para Ajustes: cada skill del dir con su estado learned/practiced.
    public func overview() -> [SkillOverview] {
        let disabled = disabledNames()
        return loadSkills().map { skill in
            let stats = stats(skill.name)
            return SkillOverview(name: skill.name,
                                 summary: skill.description.isEmpty ? skill.when : skill.description,
                                 practiced: stats?.practiced ?? false,
                                 totalSuccess: stats?.totalSuccess ?? 0,
                                 totalFail: stats?.totalFail ?? 0,
                                 successStreak: stats?.successStreak ?? 0,
                                 disabled: disabled.contains(skill.name))
        }
    }

    // MARK: - practice / automatize

    /// Registra el resultado de una ejecución del skill. Éxito suma al streak;
    /// fallo lo resetea (desautomatización dirigida por lo Real, §5.7).
    public func practice(_ name: String, success: Bool) {
        let ts = now().timeIntervalSince1970
        try? queue.write { db in
            let existing = try Row.fetchOne(db, sql: "SELECT * FROM skill_practice WHERE skill_name=?", arguments: [name])
            let prevStreak = (existing?["success_streak"] as Int?) ?? 0
            let prevSuccess = (existing?["total_success"] as Int?) ?? 0
            let prevFail = (existing?["total_fail"] as Int?) ?? 0
            let streak = success ? prevStreak + 1 : 0
            let practiced = streak >= self.practiceThreshold ? 1 : 0
            try db.execute(sql: """
                INSERT INTO skill_practice
                    (skill_name, success_streak, total_success, total_fail, practiced, updated_at)
                VALUES (?,?,?,?,?,?)
                ON CONFLICT(skill_name) DO UPDATE SET
                    success_streak=excluded.success_streak,
                    total_success=excluded.total_success,
                    total_fail=excluded.total_fail,
                    practiced=excluded.practiced,
                    updated_at=excluded.updated_at
                """, arguments: [name, streak, prevSuccess + (success ? 1 : 0),
                                 prevFail + (success ? 0 : 1), practiced, ts])
        }
    }

    /// Desenlace de un turno con el skill inyectado: `.neutral` no toca contadores.
    public func practice(_ name: String, outcome: SkillOutcome) {
        switch outcome {
        case .success: practice(name, success: true)
        case .failure: practice(name, success: false)
        case .neutral: break
        }
    }

    public func isPracticed(_ name: String) -> Bool {
        (try? queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT practiced FROM skill_practice WHERE skill_name=?", arguments: [name])
        }).flatMap { $0 } ?? false
    }

    public func stats(_ name: String) -> SkillStats? {
        try? queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM skill_practice WHERE skill_name=?", arguments: [name])
                .map {
                    SkillStats(name: name,
                               successStreak: $0["success_streak"] ?? 0,
                               totalSuccess: $0["total_success"] ?? 0,
                               totalFail: $0["total_fail"] ?? 0,
                               practiced: ($0["practiced"] as Int? ?? 0) == 1)
                }
        } ?? nil
    }

    /// Un skill practiced se compila: los pasos aferentes corren sin LLM paso a
    /// paso; los eferentes se separan y SIEMPRE piden ok. nil si no está practiced.
    public func automatize(_ name: String) -> CompiledSkill? {
        guard isPracticed(name), let skill = loadSkills().first(where: { $0.name == name }) else { return nil }
        var afferent: [String] = []
        var efferent: [String] = []
        for step in skill.steps {
            if Self.efferentTools.contains(where: { step.hasPrefix($0) }) { efferent.append(step) }
            else { afferent.append(step) }
        }
        return CompiledSkill(name: name, afferentSteps: afferent, efferentSteps: efferent)
    }

    /// Desautomatización explícita (el Consolidator la puede invocar si lo Real
    /// insiste sobre el compilado): vuelve a declarativo.
    public func deautomatize(_ name: String) {
        try? queue.write { db in
            try db.execute(sql: "UPDATE skill_practice SET practiced=0, success_streak=0, updated_at=? WHERE skill_name=?",
                           arguments: [self.now().timeIntervalSince1970, name])
        }
    }

    // MARK: - Parseo del markdown portable

    static func parse(_ text: String) -> Skill? {
        let lines = text.components(separatedBy: "\n")
        guard let firstDelim = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return nil
        }
        let rest = lines[(firstDelim + 1)...]
        guard let secondRel = rest.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return nil
        }
        let frontMatter = Array(lines[(firstDelim + 1)..<secondRel])
        let body = lines[(secondRel + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        var name = ""
        var when = ""
        var description = ""
        var steps: [String] = []
        var requires: [String] = []
        var listKey: String?
        for raw in frontMatter {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- "), let key = listKey {
                let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if key == "steps" { steps.append(item) } else { requires.append(item) }
                continue
            }
            listKey = nil
            if let value = Self.value(of: "name", in: line) { name = value }
            else if let value = Self.value(of: "when", in: line) { when = value }
            else if let value = Self.value(of: "description", in: line) { description = value }
            else if let value = Self.value(of: "steps", in: line) {
                if value.isEmpty { listKey = "steps" } else { steps = Self.inlineList(value) }
            } else if let value = Self.value(of: "requires_tools", in: line) {
                if value.isEmpty { listKey = "requires_tools" } else { requires = Self.inlineList(value) }
            }
        }
        guard !name.isEmpty else { return nil }
        return Skill(name: name, when: when, steps: steps, body: body,
                     description: description, requiresTools: requires)
    }

    /// `[a, b]` o `a, b` → ["a", "b"].
    private static func inlineList(_ value: String) -> [String] {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func value(of key: String, in line: String) -> String? {
        guard line.hasPrefix("\(key):") else { return nil }
        return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
    }

    /// Palabras vacías (es/en) que no dicen nada del gatillo.
    static let stopwords: Set<String> = [
        "que", "del", "los", "las", "una", "unos", "unas", "con", "por", "para", "como",
        "cual", "cuales", "cuando", "donde", "pero", "mas", "muy", "este", "esta", "esto",
        "ese", "esa", "eso", "sus", "mis", "tus", "nos", "les", "hay", "tengo", "tiene",
        "dame", "puedes", "podrias", "quiero", "favor", "hola", "gracias", "algo", "todo",
        "the", "and", "for", "with", "you", "please", "what", "can",
    ]

    /// Tokens normalizados: minúsculas, sin diacríticos, ≥3 chars, sin stopwords,
    /// stem por prefijo de 5 chars (inflexión del español sin diccionario).
    static func tokens(_ s: String) -> Set<String> {
        Set(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
            .map { String($0.prefix(5)) })
    }
}
