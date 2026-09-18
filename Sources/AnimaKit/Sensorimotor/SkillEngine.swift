// SkillEngine.swift — skills como secuencias nombradas de tool calls (§5.7, v1
// mínimo; el spec marca que YA EXISTE). Actor. Los skills son markdown portable
// con front-matter (name/when/steps) cargado de un dir sandbox `skills/`.
//   match(turn:)      — el mejor skill por overlap con `when` (0 LLM).
//   practice(_,_)     — contador de éxitos/fallos; ≥3 éxitos seguidos ⇒ practiced.
//   automatize(_)     — un skill practiced se compila a la secuencia de pasos
//                       aferentes ejecutable sin re-consultar al LLM paso a paso.
// Hook documentado: los pasos EFERENTES de un CompiledSkill SIEMPRE siguen pidiendo
// ok (nunca se automatiza una escritura); en v1 `practiced` es el estado terminal
// y el runner que ejecuta un CompiledSkill en el loop queda como extensión.

import Foundation
import GRDB

/// Un skill declarativo: secuencia nombrada de pasos (tool calls) con su gatillo.
public struct Skill: Sendable, Equatable, Identifiable {
    public var name: String
    public var when: String       // descripción del gatillo (para el match)
    public var steps: [String]    // pasos en orden, p.ej. "calendar.list(days_ahead=1)"
    public var body: String       // prosa opcional tras el front-matter

    public var id: String { name }

    public init(name: String, when: String, steps: [String], body: String = "") {
        self.name = name
        self.when = when
        self.steps = steps
        self.body = body
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
    private let directory: URL?
    private let now: @Sendable () -> Date
    private let practiceThreshold: Int
    /// Prefijos de tool considerados eferentes (escriben): nunca se automatizan.
    private static let efferentTools: Set<String> = ["calendar.create", "calendar.delete",
                                                      "reminders.create", "reminders.complete",
                                                      "notes.write", "notes.append"]

    public init(queue: DatabaseQueue, directory: URL? = nil,
                practiceThreshold: Int = 3,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.queue = queue
        self.directory = directory
        self.practiceThreshold = practiceThreshold
        self.now = now
    }

    // MARK: - Carga

    /// Carga los skills del dir sandbox (archivos *.md con front-matter). Sin dir
    /// o dir inexistente ⇒ vacío (el harness funciona sin skills).
    public func loadSkills() -> [Skill] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return Self.parse(text)
            }
    }

    // MARK: - match

    /// El mejor skill para un turno por overlap de tokens con `when`+`name` (0 LLM).
    /// nil si ningún skill supera el umbral mínimo de overlap.
    public func match(_ task: String) -> Skill? {
        let query = Self.tokens(task)
        guard !query.isEmpty else { return nil }
        var best: (skill: Skill, score: Double)?
        for skill in loadSkills() {
            let trigger = Self.tokens(skill.when + " " + skill.name)
            guard !trigger.isEmpty else { continue }
            let overlap = Double(query.intersection(trigger).count)
            let score = overlap / Double(min(query.count, trigger.count))
            if overlap > 0, score >= 0.34, best == nil || score > best!.score {
                best = (skill, score)
            }
        }
        return best?.skill
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
        var steps: [String] = []
        var inSteps = false
        for raw in frontMatter {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- "), inSteps {
                steps.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                continue
            }
            inSteps = false
            if let value = Self.value(of: "name", in: line) { name = value }
            else if let value = Self.value(of: "when", in: line) { when = value }
            else if line == "steps:" || line.hasPrefix("steps:") {
                inSteps = true
                let inline = Self.value(of: "steps", in: line) ?? ""
                if !inline.isEmpty {
                    steps = inline.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    inSteps = false
                }
            }
        }
        guard !name.isEmpty else { return nil }
        return Skill(name: name, when: when, steps: steps, body: body)
    }

    private static func value(of key: String, in line: String) -> String? {
        guard line.hasPrefix("\(key):") else { return nil }
        return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
    }

    static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 })
    }
}
