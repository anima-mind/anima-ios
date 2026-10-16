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
        // Sin una señal de dejar algo no hay nada que leer (y no se corre ninguna regex).
        guard !folded.isEmpty, hasCue(folded) else { return nil }
        // Recordatorios ("no me recuerdes", "deja de recordarme"), la agenda o las
        // notas no son metas.
        let elsewhere = ["recuerd", "recordar", "avis", "cita", "agenda", "evento", "calendario", "nota",
                         "reunion", "alarma"]
        if elsewhere.contains(where: folded.contains), !folded.contains("meta"), !folded.contains("objetivo") {
            return nil
        }
        let chars = Array(original)
        let foldedChars = Array(folded)
        let ns = folded as NSString
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: folded) else { return "" }
            let lower = folded.distance(from: folded.startIndex, to: swiftRange.lowerBound)
            let upper = folded.distance(from: folded.startIndex, to: swiftRange.upperBound)
            let piece = chars.count == foldedChars.count ? String(chars[lower..<upper]) : String(folded[swiftRange])
            return clean(piece)
        }
        func first(_ regex: NSRegularExpression, from location: Int = 0) -> NSTextCheckingResult? {
            regex.firstMatch(in: folded, range: NSRange(location: location, length: ns.length - location))
        }

        // "quiero Y en vez de X" / "en vez de X, mejor Y".
        if let m = first(Self.insteadOfAfter) {
            let old = group(m, 2), new = group(m, 1)
            return old.isEmpty ? nil : Parsed(old: old, new: new.isEmpty ? nil : new)
        }
        if let m = first(Self.insteadOfBefore) {
            let old = group(m, 1), new = group(m, 2)
            return old.isEmpty ? nil : Parsed(old: old, new: new.isEmpty ? nil : new)
        }

        // "la meta de ahorrar ya no me interesa", "lo de correr ya no va".
        if let m = first(Self.noLongerInterested) {
            let old = group(m, 1)
            return GoalDedupe.key(old).terms.isEmpty ? nil : Parsed(old: old, new: nil)
        }

        guard let m = first(Self.drop) else { return nil }
        var old = group(m, 1)
        // "ya no quiero que me…" no deja una meta; "ya no me…" tampoco nombra cuál.
        if ["que ", "me ", "te ", "se ", "lo ", "la "].contains(where: fold(old).hasPrefix) { return nil }
        for prefix in ["seguir ", "con "] where fold(old).hasPrefix(prefix) { old = String(old.dropFirst(prefix.count)) }
        guard !GoalDedupe.key(old).terms.isEmpty || fold(old).contains("meta") else { return nil }
        var new: String?
        if let n = first(Self.replacement, from: m.range.location + m.range.length) {
            let piece = group(n, 1)
            if !GoalDedupe.key(piece).terms.isEmpty { new = piece }
        }
        return Parsed(old: old, new: new)
    }

    // Compiladas UNA vez (ICU). Medido en CI (runner de 3 núcleos): las `Regex`
    // literales de Swift se reconstruían en cada llamada (1–5 ms aquí, mucho más
    // allá) y, sincrónicas en el pool cooperativo, dejaban sin hilos a la suite.
    static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    static let insteadOfAfter = regex(#"^(?:(?:oye|ya|bueno|mira),? )*(?:mejor )?(?:quiero|prefiero|me propongo) (.+?),? en (?:vez|lugar) de (.+?)$"#)
    static let insteadOfBefore = regex(#"en (?:vez|lugar) de (.+?)[,;]\s*(?:mejor |ahora )?(?:quiero |prefiero |voy a |me propongo )?(.+?)$"#)
    static let noLongerInterested = regex(#"^(?:(?:oye|bueno|mira),? )*(?:(?:mi|la|esa) meta de |lo de |eso de )?(.+?) ya no (?:me interesa|va|me importa|lo quiero|la quiero)\b"#)
    static let drop = regex(#"(?:ya no quiero|ya no voy a|no quiero seguir(?: con)?|ya no me interesa|ya no|olvida(?:te de| la| mi)?|elimina|borra|cancela|quita|abandona|deja(?:r)? de|dejo de|desisto de)\s+(?:(?:mi|la|esa|lo de|de|el) )?(?:meta|objetivo)?\s*(?:de |del |que era )?(.+?)(?=\s*[,;.!]|\s+(?:mejor|sino|ahora|prefiero|y (?:mejor|ahora|quiero))\b|$)"#)
    static let replacement = regex(#"(?:mejor|sino(?: que)?|ahora|prefiero|y (?:mejor|ahora))\s+(?:quiero |prefiero |voy a |me propongo |mi meta es |la meta es )?(.+?)\s*[.;!]*$"#)

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
