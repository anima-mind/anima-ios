// GoalDrop.swift — "ya no quiero ahorrar, mejor quiero abonar a la deuda"
// (campo). Lectura determinista (sin LLM) de cuándo el dueño DEJA una meta y,
// si la cambia por otra, cuál: la usa el modelo local (repara lo que el 3B no
// extrae) y el sueño (una meta solo se deja si el mensaje del dueño lo dice).

import Foundation

public enum GoalDrop {

    /// Lo que dijo el dueño: la meta que deja (en sus palabras) y la nueva, si la nombró.
    public struct Parsed: Sendable, Equatable {
        public var old: String
        public var new: String?
    }

    /// ¿El texto trae una señal de dejar o cambiar algo? (filtro del sueño: un
    /// abandono que el modelo propone sin esta señal en el mensaje no se aplica).
    public static func hasCue(_ text: String) -> Bool {
        let folded = fold(text)
        return cues.contains { folded.contains($0) }
    }

    static let cues = [
        "ya no", "no quiero", "no voy a", "olvida", "cancela", "elimina", "borra", "quita", "deja de", "dejo de",
        "dejar de", "dejare de", "abandon", "mejor ", "en vez de", "en lugar de", "desisto", "no me interesa",
        "cambia la meta", "cambiar la meta", "cambio la meta", "cambio de meta", "renuncio",
    ]

    /// "ya no quiero ahorrar, mejor quiero abonar a la deuda 5M cada quincena" ⇒
    /// old "ahorrar", new "abonar a la deuda 5M cada quincena". nil si el texto no
    /// deja una meta (p. ej. "ya no quiero que me recuerdes…", que es de recordatorios).
    public static func parse(_ text: String) -> Parsed? {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = fold(original)
        guard !folded.isEmpty else { return nil }
        // Recordatorios ("no me recuerdes", "deja de recordarme"), la agenda o las
        // notas no son metas.
        let elsewhere = ["recuerd", "recordar", "avis", "cita", "agenda", "evento", "calendario", "nota",
                         "reunion", "alarma"]
        if elsewhere.contains(where: folded.contains), !folded.contains("meta"), !folded.contains("objetivo") {
            return nil
        }
        let chars = Array(original)
        let foldedChars = Array(folded)
        func cut(_ range: Range<String.Index>) -> String {
            let lower = folded.distance(from: folded.startIndex, to: range.lowerBound)
            let upper = folded.distance(from: folded.startIndex, to: range.upperBound)
            let piece = chars.count == foldedChars.count ? String(chars[lower..<upper]) : String(folded[range])
            return clean(piece)
        }

        // "quiero Y en vez de X" / "en vez de X, mejor Y".
        if let m = folded.firstMatch(of: /^(?:(?:oye|ya|bueno|mira),? )*(?:mejor )?(?:quiero|prefiero|me propongo) (.+?),? en (?:vez|lugar) de (.+?)$/) {
            let old = cut(m.2.startIndex..<m.2.endIndex), new = cut(m.1.startIndex..<m.1.endIndex)
            return old.isEmpty ? nil : Parsed(old: old, new: new.isEmpty ? nil : new)
        }
        if let m = folded.firstMatch(of: /en (?:vez|lugar) de (.+?)[,;]\s*(?:mejor |ahora )?(?:quiero |prefiero |voy a |me propongo )?(.+?)$/) {
            let old = cut(m.1.startIndex..<m.1.endIndex), new = cut(m.2.startIndex..<m.2.endIndex)
            return old.isEmpty ? nil : Parsed(old: old, new: new.isEmpty ? nil : new)
        }

        // "la meta de ahorrar ya no me interesa", "lo de correr ya no va".
        if let m = folded.firstMatch(of: /^(?:(?:oye|bueno|mira),? )*(?:(?:mi|la|esa) meta de |lo de |eso de )?(.+?) ya no (?:me interesa|va|me importa|lo quiero|la quiero)\b/) {
            let old = cut(m.1.startIndex..<m.1.endIndex)
            return GoalDedupe.key(old).terms.isEmpty ? nil : Parsed(old: old, new: nil)
        }

        let drop = /(?:ya no quiero|ya no voy a|no quiero seguir(?: con)?|ya no me interesa|ya no|olvida(?:te de| la| mi)?|elimina|borra|cancela|quita|abandona|deja(?:r)? de|dejo de|desisto de)\s+(?:(?:mi|la|esa|lo de|de|el) )?(?:meta|objetivo)?\s*(?:de |del |que era )?(.+?)(?=\s*[,;.!]|\s+(?:mejor|sino|ahora|prefiero|y (?:mejor|ahora|quiero))\b|$)/
        guard let m = folded.firstMatch(of: drop) else { return nil }
        var old = cut(m.1.startIndex..<m.1.endIndex)
        // "ya no quiero que me…" no deja una meta; "ya no me…" tampoco nombra cuál.
        if ["que ", "me ", "te ", "se ", "lo ", "la "].contains(where: fold(old).hasPrefix) { return nil }
        for prefix in ["seguir ", "con "] where fold(old).hasPrefix(prefix) { old = String(old.dropFirst(prefix.count)) }
        guard !GoalDedupe.key(old).terms.isEmpty || fold(old).contains("meta") else { return nil }
        var new: String?
        let rest = folded[m.range.upperBound...]
        if let n = rest.firstMatch(of: /(?:mejor|sino(?: que)?|ahora|prefiero|y (?:mejor|ahora))\s+(?:quiero |prefiero |voy a |me propongo |mi meta es |la meta es )?(.+?)\s*[.;!]*$/) {
            let piece = cut(n.1.startIndex..<n.1.endIndex)
            if !GoalDedupe.key(piece).terms.isEmpty { new = piece }
        }
        return Parsed(old: old, new: new)
    }

    static func clean(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for suffix in [" por favor", " porfa", " gracias"] where fold(out).hasSuffix(suffix) {
            out = String(out.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    static func fold(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
    }
}
