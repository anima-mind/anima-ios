// GoalMergeV17.swift — la migración v17-goal-dedupe CONGELADA (review #34):
// una migración no puede depender de código vivo (OtherModel.goal(from:),
// GoalDedupe) que cambia con columnas o reglas futuras. Lee columnas
// explícitas por SQL y usa una copia fija de la normalización de batch 8.
// NO editar: si cambian las reglas, va en una migración nueva.

import Foundation
import GRDB

enum GoalMergeV17 {
    static let reason = "duplicada"

    private struct Row17 {
        var id: String, statement: String, source: String, status: String
        var cadence: String, hour: Int, minute: Int, weekday: Int?
    }

    static func register(_ m: inout DatabaseMigrator) {
        m.registerMigration("v17-goal-dedupe") { db in
            try db.execute(sql: "ALTER TABLE goal ADD COLUMN status_reason TEXT NULL")
            try run(db, now: Date())
        }
    }

    @discardableResult
    static func run(_ db: Database, now: Date) throws -> Int {
        let ts = now.timeIntervalSince1970
        let open = try Row.fetchAll(db, sql: """
            SELECT id, statement, source, status, checkin_cadence, checkin_hour, checkin_minute, checkin_weekday
            FROM goal WHERE status IN ('active','pending_confirmation')
            ORDER BY CASE source WHEN 'stated' THEN 0 WHEN 'inferred' THEN 1 ELSE 2 END, created_at ASC
            """).map { r in
            Row17(id: r["id"], statement: r["statement"], source: r["source"], status: r["status"],
                  cadence: r["checkin_cadence"] ?? "none", hour: r["checkin_hour"] ?? 20,
                  minute: r["checkin_minute"] ?? 0, weekday: r["checkin_weekday"])
        }
        // Sin transitividad: cada duplicado es equivalente a la canónica (la 1.ª del grupo).
        var clusters: [[Row17]] = []
        for goal in open {
            if let index = clusters.firstIndex(where: { V17Dedupe.equivalent($0[0].statement, goal.statement) }) {
                clusters[index].append(goal)
            } else {
                clusters.append([goal])
            }
        }
        var merged = 0
        for cluster in clusters {
            let keeper = cluster[0]
            var cadence = (keeper.cadence, keeper.hour, keeper.minute, keeper.weekday)
            for dup in cluster.dropFirst() {
                for table in ["goal_checkin", "anima_reminder", "intention"] {
                    try db.execute(sql: "UPDATE \(table) SET goal_id=? WHERE goal_id=?", arguments: [keeper.id, dup.id])
                }
                if cadence.0 == "none", dup.cadence != "none" { cadence = (dup.cadence, dup.hour, dup.minute, dup.weekday) }
                try db.execute(sql: "UPDATE goal SET status='abandoned', status_reason=?, updated_at=? WHERE id=?",
                               arguments: [reason, ts, dup.id])
                merged += 1
            }
            let statement = V17Dedupe.neutral(keeper.statement)
            try db.execute(sql: """
                UPDATE goal SET statement=?, checkin_cadence=?, checkin_hour=?, checkin_minute=?, checkin_weekday=?
                WHERE id=?
                """, arguments: [statement, cadence.0, cadence.1, cadence.2,
                                 cadence.0 == "weekly" ? cadence.3 : nil, keeper.id])
        }
        return merged
    }
}

/// Copia FIJA de GoalDedupe tal como quedó en batch 8 (solo para v17).
enum V17Dedupe {

    /// Enunciado neutral (segunda persona/infinitivo): "Bajar 10 kg", nunca
    /// "El dueño quiere bajar 10 kg". Conserva las palabras del dueño.
    static func neutral(_ statement: String) -> String {
        var text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = fold(text)
        var stripped = false
        for prefix in prefixes {
            guard let range = folded.range(of: prefix, options: [.regularExpression, .anchored]) else { continue }
            let cut = folded.distance(from: folded.startIndex, to: range.upperBound)
            text = String(text.dropFirst(cut)).trimmingCharacters(in: .whitespacesAndNewlines)
            stripped = true
            break
        }
        while let last = text.last, ".;".contains(last) { text.removeLast() }
        guard let first = text.first else { return statement.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Sin prefijo, las palabras del dueño tal cual; tras quitarlo, abre en mayúscula.
        return stripped ? first.uppercased() + text.dropFirst() : text
    }

    /// Prefijos en tercera persona o de declaración (sobre el texto plegado).
    static let prefixes = [
        #"(el|la) (dueno|duena|usuario|usuaria) (quiere|desea|busca|necesita|planea|pretende|se propone|tiene (la meta|como meta|el objetivo) de) "#,
        #"[a-z]+ (quiere|desea|busca|necesita|planea|pretende|se propone) "#,
        #"(yo )?(quiero|deseo|necesito|planeo|me propongo|me gustaria|tengo que) "#,
        #"(mi|su) (meta|objetivo) (es|seria) "#,
        #"(meta|objetivo): "#,
    ]

    /// ¿Dos enunciados son la misma meta? Mismos números y el mismo contenido;
    /// uno puede tener de más SOLO marcadores de cadencia ("Correr 5 km" ≈
    /// "Correr 5 km cada semana"), nunca contenido ("Correr una maratón" ≠
    /// "Correr una media maratón", "Aprender inglés" ≠ "Aprender inglés y francés").
    static func equivalent(_ a: String, _ b: String) -> Bool {
        let ka = key(a), kb = key(b)
        guard !ka.terms.isEmpty, !kb.terms.isEmpty, ka.numbers == kb.numbers else { return false }
        // Periodos explícitos distintos = metas distintas ("1 libro al mes" ≠
        // "1 libro a la semana"); el marcador solo se ignora si uno no lo trae.
        let pa = ka.terms.intersection(periods), pb = kb.terms.intersection(periods)
        if !pa.isEmpty, !pb.isEmpty, pa != pb { return false }
        let core = { (terms: Set<String>) in terms.subtracting(cadence) }
        let ca = core(ka.terms), cb = core(kb.terms)
        return !ca.isEmpty && ca == cb
    }

    /// Marcadores de frecuencia: no cambian QUÉ es la meta.
    static let cadence: Set<String> = [
        "cada", "semana", "dia", "mes", "ano", "todo", "toda", "todos", "todas", "noche", "siempre", "habito",
        "regularmente", "constante", "constantemente", "seguido", "quincena",
    ]
    /// Periodos (canónicos): si ambas metas traen uno y difieren, no son la misma.
    static let periods: Set<String> = ["dia", "semana", "quincena", "mes", "ano"]

    struct Key: Equatable {
        var terms: Set<String>
        var numbers: Set<String>
    }

    static func key(_ statement: String) -> Key {
        var text = fold(neutral(statement))
        // "10kg" → "10 kg"; "1.5" y "1,5" → "1.5".
        text = text.replacingOccurrences(of: #"(\d)([a-z])"#, with: "$1 $2", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(\d),(\d)"#, with: "$1.$2", options: .regularExpression)
        let tokens = text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
        var terms: Set<String> = []
        var numbers: Set<String> = []
        for raw in tokens {
            if Double(raw) != nil {
                numbers.insert(raw)
                terms.insert(raw)
                continue
            }
            let token = canonical(raw)
            guard !stopwords.contains(token), !fillers.contains(token) else { continue }
            terms.insert(token)
        }
        return Key(terms: terms, numbers: numbers)
    }

    static func canonical(_ raw: String) -> String {
        if let mapped = synonyms[raw] { return mapped }
        var token = raw
        if token.count > 4, token.hasSuffix("s") { token.removeLast() }   // plural simple
        return synonyms[token] ?? token
    }

    static func fold(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
    }

    static let synonyms: [String: String] = {
        var map: [String: String] = [:]
        let groups: [String: [String]] = [
            "bajar": ["bajar", "perder", "reducir", "rebajar", "adelgazar"],
            "kg": ["kg", "kgs", "kilo", "kilos", "kilogramo", "kilogramos"],
            "entrenar": ["entrenar", "ejercicio", "ejercitar", "ejercitarme", "entrenamiento", "gimnasio", "gym"],
            "correr": ["correr", "trotar"],
            "ahorrar": ["ahorrar", "ahorro", "juntar"],
            "leer": ["leer", "lectura"],
            "dormir": ["dormir", "descansar", "sueno"],
            "hora": ["hora", "horas", "h"],
            "millon": ["millon", "millones", "palo", "palos"],
            "semana": ["semana", "semanal", "semanalmente"],
            "dia": ["dia", "dias", "diario", "diaria", "diariamente"],
            "mes": ["mes", "meses", "mensual", "mensualmente"],
            "ano": ["ano", "anos", "anual", "anualmente"],
            "quincena": ["quincena", "quincenas", "quincenal", "quincenalmente"],
        ]
        for (canonical, words) in groups { for word in words { map[word] = canonical } }
        return map
    }()

    static let stopwords: Set<String> = [
        "el", "la", "lo", "los", "las", "un", "una", "uno", "unos", "unas", "de", "del", "al", "a", "en", "y", "o",
        "que", "con", "para", "por", "mi", "mis", "su", "sus", "tu", "tus", "me", "se", "le", "x", "vez", "veces",
        "mas", "muy", "este", "esta", "ese", "esa",
    ]
    /// Relleno que no cambia la meta ("de peso", "en un plazo determinado").
    static let fillers: Set<String> = [
        "peso", "plazo", "determinado", "cierto", "tiempo", "meta", "objetivo", "lograr", "llegar", "forma",
        "manera", "pronto", "posible", "proximo", "proxima", "algun", "alguna", "corporal", "ir", "hacer",
    ]
}
