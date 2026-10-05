// DistillGuard.swift — cinturón y tirantes del destilado (campo batch 3, FIX B).
// El prompt pide SOLO hechos durables sobre el dueño y su mundo; este guard es
// determinista (0 LLM, testeable) y rechaza lo que el modelo deje pasar igual:
//   (a) preguntas del dueño — terminan en "?" o abren con interrogativo
//   (b) meta del asistente — el sujeto es el asistente / Anima / el nombre del self
//   (c) eco — duplica >80% literal un turno del dueño de la sesión fuente
// Los rechazos van al cycle_log con su razón (auditables), jamás al Brain.

import Foundation
import GRDB

public enum DistillGuard {

    public enum Rejection: String, Sendable, Equatable, Codable {
        case question = "pregunta del dueño (eco)"
        case assistantMeta = "meta del asistente"
        case echo = "eco literal de un turno"
    }

    /// Razón con la que la migración invalida memorias legacy (bi-temporal).
    public static let migrationReason = "destilado v2: eco/meta"

    /// Umbral de similitud literal para (c).
    public static let echoThreshold = 0.8

    /// Evalúa un candidato. `selfName`: nombre vivo del self ("Betty").
    /// `sourceTurns`: textos del dueño de la sesión fuente (para el eco).
    public static func reject(_ content: String, selfName: String? = nil,
                              sourceTurns: [String] = []) -> Rejection? {
        if isQuestion(content) { return .question }
        if isAssistantMeta(content, selfName: selfName) { return .assistantMeta }
        if isEcho(content, of: sourceTurns) { return .echo }
        return nil
    }

    // MARK: (a) preguntas

    /// Interrogativos con tilde (o verbos de pedido) ⇒ pregunta siempre.
    private static let interrogatives: [String] = [
        "qué", "quién", "quiénes", "cómo", "cuándo", "dónde", "adónde", "por qué", "cuál", "cuáles",
        "cuánto", "cuánta", "cuántos", "cuántas",
        "puedes", "podrías", "cuéntame", "cuentame", "dime", "explícame",
        "explicame", "sabes", "me dices", "me puedes", "me cuentas", "oye",
    ]
    /// Sin tilde son ambiguos ("Cuando viaja, prefiere ventana" es un hecho):
    /// solo cuentan como pregunta si la frase no tiene la coma de una subordinada.
    private static let bareInterrogatives: [String] = [
        "que", "quien", "como", "cuando", "donde", "por que", "porque", "cual", "cuanto",
    ]

    static func isQuestion(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("?") || trimmed.hasPrefix("¿") { return true }
        let lower = stripVocative(trimmed.lowercased())
        if interrogatives.contains(where: { startsWithWord(lower, $0) }) { return true }
        if bareInterrogatives.contains(where: { startsWithWord(lower, $0) }), !lower.contains(",") {
            return true
        }
        return false
    }

    /// "Betty cuéntame…" / "Oye, ¿qué…": el vocativo inicial no cambia que sea pregunta.
    private static func stripVocative(_ lower: String) -> String {
        let words = lower.split(separator: " ", maxSplits: 1).map(String.init)
        guard words.count == 2 else { return lower }
        let first = words[0].trimmingCharacters(in: CharacterSet(charactersIn: ",:"))
        let rest = words[1]
        // Solo ante un interrogativo inequívoco (con tilde o verbo de pedido):
        // "Betty cuéntame…" sí; "Trabaja como arquitecto" no.
        if interrogatives.contains(where: { startsWithWord(rest, $0) }),
           !first.isEmpty, first.count <= 16 {
            return rest
        }
        return lower
    }

    // MARK: (b) meta del asistente

    private static let assistantSubjects: [String] = [
        "el asistente", "la asistente", "este asistente", "esta asistente", "tu asistente",
        "anima", "el modelo", "la ia", "la inteligencia artificial", "el sistema", "el bot",
        "the assistant", "assistant", "soy un asistente", "soy una asistente", "como asistente",
    ]

    static func isAssistantMeta(_ content: String, selfName: String?) -> Bool {
        let lower = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var subjects = assistantSubjects
        if let name = selfName?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty {
            subjects.append(name)
        }
        return subjects.contains { startsWithWord(lower, $0) }
    }

    // MARK: (c) eco literal

    static func isEcho(_ content: String, of turns: [String]) -> Bool {
        let candidate = normalize(content)
        guard !candidate.isEmpty else { return false }
        for turn in turns {
            let source = normalize(turn)
            guard !source.isEmpty else { continue }
            if source == candidate { return true }
            // El candidato es (casi) una oración literal del turno.
            if source.contains(candidate), Double(candidate.count) / Double(source.count) >= echoThreshold {
                return true
            }
            if similarity(candidate, source) > echoThreshold { return true }
        }
        return false
    }

    /// Similitud 1 − Levenshtein/max(len). Acotada a 400 chars por lado.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.prefix(400)), y = Array(b.prefix(400))
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[y.count]) / Double(longest)
    }

    /// minúsculas, sin tildes ni puntuación, espacios colapsados.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    private static func startsWithWord(_ lower: String, _ word: String) -> Bool {
        guard lower.hasPrefix(word) else { return false }
        let rest = lower.dropFirst(word.count)
        guard let next = rest.first else { return true }
        return !next.isLetter && !next.isNumber
    }
}

// MARK: - Migración de limpieza (destilado v2)

public enum DistillMigration {
    static let metaKey = "distill_v2_migrated"

    /// Al abrir post-update: re-evalúa las memorias vivas contra (a) y (b) e
    /// invalida las que caen con `DistillGuard.migrationReason` (bi-temporal: no
    /// borra, el dueño las ve tachadas con razón en el browser). Corre UNA vez
    /// (flag en consolidation_meta). Devuelve cuántas invalidó.
    @discardableResult
    public static func runIfNeeded(queue: DatabaseQueue, brain: Brain, selfName: String?) async throws -> Int {
        let done = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM consolidation_meta WHERE key=?", arguments: [metaKey])
        }
        guard done == nil else { return 0 }
        let rows: [(id: String, content: String)] = try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, content FROM memory
                WHERE invalidated_at IS NULL AND kind IN ('semantic','episodic','procedural','reflection')
                """).map { (id: $0["id"], content: $0["content"]) }
        }
        var invalidated = 0
        for row in rows where DistillGuard.isQuestion(row.content)
            || DistillGuard.isAssistantMeta(row.content, selfName: selfName) {
            try await brain.invalidate(id: row.id, reason: DistillGuard.migrationReason)
            invalidated += 1
        }
        try await queue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO consolidation_meta (key, value) VALUES (?,?)",
                           arguments: [metaKey, String(Date().timeIntervalSince1970)])
        }
        return invalidated
    }
}
