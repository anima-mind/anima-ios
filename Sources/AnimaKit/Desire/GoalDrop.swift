// GoalDrop.swift — "ya no quiero ahorrar, mejor quiero abonar a la deuda"
// (campo). Lectura determinista (sin LLM) de cuándo el dueño DEJA una meta y,
// si la cambia por otra, cuál. La usan el modelo local (repara lo que el 3B no
// extrae) y el sueño (una meta solo se deja si el mensaje del dueño lo dice).
//
// Regla (review #45): ante la duda NO se actúa. Solo es dejar con primera
// persona e intención explícita sobre la meta ("ya no quiero X", "deja/quita/
// borra/olvida mi meta de X", "cambia mi meta de X por Y", "ya no X, mejor Y").
// Tercera persona ("mi amigo dejó…"), lo temporal ("hoy", "este mes"), la
// capacidad ("no puedo"), lo que no es meta ("hambre") y la broma ("era
// broma") no dejan nada; la duda ("no sé", "pensando en") y las señales a
// medias ("dejo el gym", "me rindo con el ahorro") solo preguntan.

import Foundation

public enum GoalDrop {

    /// Lo que dijo el dueño: la meta que deja (en sus palabras) y la nueva, si la nombró.
    public struct Parsed: Sendable, Equatable {
        public var old: String
        public var new: String?
    }

    /// La lectura del texto del dueño.
    public enum Reading: Sendable, Equatable {
        /// Deja (o cambia) una meta, sin duda: se puede actuar.
        case drop(Parsed)
        /// Parece que quiere dejar algo (la meta en sus palabras): se pregunta, no se actúa.
        case unclear(String)
        /// No deja ninguna meta.
        case none
    }

    /// Solo lo que se puede ejecutar: la lectura `.drop`.
    public static func parse(_ text: String) -> Parsed? {
        if case .drop(let parsed) = read(text) { return parsed }
        return nil
    }

    /// ¿El dueño dejó una meta sin duda en este texto? (guarda del sueño).
    public static func isClearDrop(_ text: String) -> Bool { parse(text) != nil }

    /// ¿El texto trae alguna señal de dejar o cambiar algo? (corte barato).
    public static func hasCue(_ text: String) -> Bool {
        let folded = fold(text)
        return cues.contains { folded.contains($0) }
    }

    static let cues = [
        "ya no", "no quiero", "no voy a", "olvida", "cancela", "elimina", "borra", "quita", "deja", "dejo", "dejar",
        "deje", "abandon", "mejor ", "en vez de", "en lugar de", "desisto", "no me interesa", "cambia", "cambio",
        "reemplaz", "renuncio", "me rindo", "ya fue", "archiva", "saca",
    ]

    public static func read(_ text: String) -> Reading {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = fold(original)
        // Sin una señal de dejar algo no hay nada que leer (y no se corre ninguna regex).
        guard !folded.isEmpty, hasCue(folded) else { return .none }
        // Recordatorios ("no me recuerdes"), la agenda o las notas no son metas.
        let elsewhere = ["recuerd", "recordar", "avis", "cita", "agenda", "evento", "calendario", "nota",
                         "reunion", "alarma"]
        if elsewhere.contains(where: folded.contains), !folded.contains("meta"), !folded.contains("objetivo") {
            return .none
        }
        let reader = Reader(original: original, folded: folded)
        // Broma o anulación, otra persona, algo pasajero, no poder o no ser una meta: nada.
        for exclusion in [annulment, thirdPerson, temporary, capacity, notAGoal] where reader.matches(exclusion) {
            return .none
        }
        // "dejó" (otra persona o pasado) no es "dejo".
        if original.lowercased().contains("dejó") { return .none }
        let doubtful = reader.matches(doubt)
        if let parsed = clear(reader) {
            return doubtful ? .unclear(parsed.old) : .drop(parsed)
        }
        if let m = reader.first(partialBare) { return .unclear(reader.group(m, "old")) }
        if let m = reader.first(partial) {
            let old = reader.group(m, "old")
            if !GoalDedupe.key(old).terms.isEmpty, !metaVerbs.contains(where: fold(old).hasPrefix) { return .unclear(old) }
        }
        return .none
    }

    /// Las formas explícitas, en orden.
    private static func clear(_ reader: Reader) -> Parsed? {
        if let m = reader.first(change) {
            let old = reader.group(m, "old"), new = reader.group(m, "new")
            if hasTerms(old), hasTerms(new) { return Parsed(old: old, new: new) }
        }
        for pattern in [insteadOfAfter, insteadOfBefore] {
            guard let m = reader.first(pattern) else { continue }
            let old = reader.group(m, "old"), new = reader.group(m, "new")
            if hasTerms(old) { return Parsed(old: old, new: hasTerms(new) ? new : nil) }
        }
        if let m = reader.first(noLongerXBetterY) {
            let old = reader.group(m, "old"), new = reader.group(m, "new")
            if hasTerms(old), hasTerms(new) { return Parsed(old: old, new: new) }
        }
        for pattern in [noLongerWant, imperativeOnGoal, firstPersonOnGoal, goalNoLongerInterests, noLongerInterested] {
            guard let m = reader.first(pattern) else { continue }
            let old = reader.group(m, "old")
            guard hasTerms(old) || fold(old).contains("meta") else { continue }
            // "ya no quiero cambiar mi meta" / "ya no quiero dejarla": habla de la acción, no deja nada.
            if metaVerbs.contains(where: fold(old).hasPrefix) { return nil }
            var new: String?
            if let n = reader.first(replacement, from: m.range.location + m.range.length) {
                let piece = reader.group(n, "new")
                if hasTerms(piece) { new = piece }
            }
            return Parsed(old: old, new: new)
        }
        return nil
    }

    static func hasTerms(_ text: String) -> Bool { !GoalDedupe.key(text).terms.isEmpty }

    static let metaVerbs = ["cambiar", "modificar", "borrar", "eliminar", "quitar", "dejar", "olvidar", "cancelar",
                            "abandonar", "que "]

    /// Recorta grupos sobre el texto plegado y devuelve las palabras originales.
    private struct Reader {
        let original: String
        let folded: String
        let chars: [Character]
        let foldedChars: [Character]
        let length: Int

        init(original: String, folded: String) {
            self.original = original
            self.folded = folded
            chars = Array(original)
            foldedChars = Array(folded)
            length = (folded as NSString).length
        }

        func first(_ regex: NSRegularExpression, from location: Int = 0) -> NSTextCheckingResult? {
            regex.firstMatch(in: folded, range: NSRange(location: location, length: max(0, length - location)))
        }

        func matches(_ regex: NSRegularExpression) -> Bool { first(regex) != nil }

        func group(_ match: NSTextCheckingResult, _ name: String) -> String {
            let range = match.range(withName: name)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: folded) else { return "" }
            let lower = folded.distance(from: folded.startIndex, to: swiftRange.lowerBound)
            let upper = folded.distance(from: folded.startIndex, to: swiftRange.upperBound)
            let piece = chars.count == foldedChars.count ? String(chars[lower..<upper]) : String(folded[swiftRange])
            return GoalDrop.clean(piece)
        }
    }

    // Compiladas UNA vez (ICU). Medido en CI (runner de 3 núcleos): las `Regex`
    // de Swift se reconstruían en cada llamada y, sincrónicas en el pool
    // cooperativo, dejaban sin hilos a la suite.
    static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    /// Un verbo en infinitivo ("ahorrar", "ir", "correrme"): la meta como la dice el dueño.
    static let infinitive = #"[a-z]*(?:ar|er|ir)(?:me|te|se|lo|la)?\b"#
    /// Lo que sigue a la meta y la corta: puntuación o el giro hacia la nueva.
    static let stop = #"(?=\s*[,;.!?]|\s+(?:mejor|sino|ahora|prefiero|y (?:mejor|ahora|quiero))\b|$)"#
    static let goalRef = #"(?:(?:mi|la|esa) (?:meta|objetivo) (?:de |del )?|lo de |lo del )"#
    static let lead = #"(?:^|[,;.!¡]\s*|\b(?:y|pero|oye|bueno|mira|sabes que|anima|entonces|ya)\s+)"#

    static let noLongerWant = regex(lead + #"(?:yo )?(?:ya no quiero|no quiero seguir|ya no quiero seguir)(?: con)? (?<old>(?:"# + goalRef + #")?"# + infinitive + #".*?|"# + goalRef + #".+?)"# + stop)
    static let imperativeOnGoal = regex(#"\b(?:deja|dejame|quita|quitame|borra|borrame|elimina|eliminame|cancela|cancelame|olvida|olvidate de|abandona|archiva|saca)\s+(?:mi|la|esa) (?:meta|objetivo) (?:de |del )?(?<old>.+?)"# + stop)
    static let firstPersonOnGoal = regex(lead + #"(?:yo )?(?:dejo|abandono|cancelo|elimino|borro|archivo|quito|suelto) (?:mi|la|esa) (?:meta|objetivo) (?:de |del )?(?<old>.+?)"# + stop)
    static let goalNoLongerInterests = regex(#"\b(?:mi|la|esa) meta de (?<old>.+?) ya no (?:me interesa|la quiero)\b"#)
    static let noLongerInterested = regex(#"\bya no me interesa (?<old>"# + infinitive + #".*?)"# + stop)
    static let change = regex(#"\b(?:cambia|cambiame|cambio|reemplaza|reemplazame|reemplazo) (?:mi|la|esa) (?:meta|objetivo) (?:de |del )?(?<old>.+?) por (?<new>.+?)\s*[.!]*$"#)
    static let insteadOfAfter = regex(lead + #"(?:mejor )?(?:quiero|prefiero) (?<new>"# + infinitive + #"[^,;]*?),? en (?:vez|lugar) de (?<old>"# + infinitive + #"[^,;.!?]*?)\s*[.!]*$"#)
    static let insteadOfBefore = regex(lead + #"en (?:vez|lugar) de (?<old>"# + infinitive + #"[^,;]*?)[,;]\s*(?:mejor |ahora )?(?:quiero|prefiero|voy a) (?<new>.+?)\s*[.!]*$"#)
    static let noLongerXBetterY = regex(#"^(?:(?:oye|bueno|mira|ya),? )*ya no (?<old>"# + infinitive + #"[^,;]*?)[,;]?\s+(?:mejor|ahora) (?:quiero |prefiero )?(?<new>.+?)\s*[.!]*$"#)
    static let replacement = regex(#"(?:mejor|sino(?: que)?|ahora|prefiero|y (?:mejor|ahora))\s+(?:quiero |prefiero |voy a |me propongo |mi meta es |la meta es )?(?<new>.+?)\s*[.;!]*$"#)

    /// Señales a medias: se pregunta.
    static let partial = regex(#"\b(?:ya no quiero|dejo|deje|dejare|abandono|me rindo con|ya fue(?: con)? lo del?|ya no voy al?|ya no hago|dejar de|dejo de|deje de)\s+(?:el |la |los |las |lo del? |con (?:el |la )?|de )?(?<old>[^,;.!?]+?)(?=\s*[,;.!?]|$)"#)

    /// "borra mi meta" sin decir cuál.
    static let partialBare = regex(#"\b(?:deja|quita|borra|elimina|cancela|olvida|abandona)\s+(?<old>(?:mi|la|esa) meta)\s*[.!]*$"#)

    static let annulment = regex(#"\b(?:era|es) (?:una |un )?(?:broma|chiste)\b|\bno es cierto\b|\bmentira\b|\bolvida(?:te de)? lo que (?:te )?dije\b|\bolvidalo\b|\bno (?:me )?hagas caso\b|\bjaja"#)
    static let thirdPerson = regex(#"\b(?:mi|tu|su|el|la|un|una) (?:amig[oa]s?|herman[oa]s?|espos[oa]|novi[oa]|mama|papa|madre|padre|jef[ea]|pareja|hij[oa]s?|soci[oa]|vecin[oa]|companer[oa]|prim[oa]|ti[oa]|cunad[oa]|colega)\b|\b(?:el|ella|ellos|ellas|alguien|nadie|la gente)\s+(?:ya no|dej|abandon|quiere|no quiere)"#)
    static let temporary = regex(#"\b(?:hoy|por hoy|esta noche|este mes|esta semana|este fin(?: de semana)?|manana|ahorita|por ahora|por unos dias|por un tiempo|un rato|esta vez|por esta vez|estos dias|este ano)\b"#)
    static let capacity = regex(#"\bno (?:puedo|pude|podre|podria|voy a poder|alcanzo|me alcanza|me da|aguanto|tengo tiempo)\b|\bya no aguanto\b"#)
    static let notAGoal = regex(#"\b(?:hambre|sed|frio|calor|azucar|sueno)\b"#)
    static let doubt = regex(#"\bno (?:se|estoy (?:tan |muy )?segur[oa])\b|\bpensando en\b|\bcreo que\b|\btal vez\b|\bquizas?\b|\ba lo mejor\b|\bdeberia\b|\bdudando\b|\bme pregunto\b|\?"#)

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
