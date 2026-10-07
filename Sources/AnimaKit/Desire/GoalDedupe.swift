// GoalDedupe.swift — una meta, una sola vez (campo batch 8 #5). En campo la
// misma meta existía 3 veces: "El dueño quiere bajar 10 kg" (extraída de
// noche, en tercera persona), "Perder 10 kg en un plazo determinado"
// (inferida por el reflection sin ver las existentes) y "Bajar 10 kg de peso"
// (declarada en el chat). El upsert solo deduplicaba por enunciado EXACTO.
// Aquí: normalización determinista (sin LLM) — minúsculas, sin tildes, sin
// "el dueño quiere / quiero / mi meta es", sinónimos (bajar≈perder≈reducir),
// números y unidades — y una comparación por contenido.

import Foundation

public enum GoalDedupe {

    /// Enunciado neutral (segunda persona/infinitivo): "Bajar 10 kg", nunca
    /// "El dueño quiere bajar 10 kg". Conserva las palabras del dueño.
    public static func neutral(_ statement: String) -> String {
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
    public static func equivalent(_ a: String, _ b: String) -> Bool {
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
