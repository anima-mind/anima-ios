// HUDSummary.swift — la respuesta del agente → su gist para el HUD (heading ≤40,
// body ≤200) + el texto que se dice por los parlantes (TTS corto). Puro. Lo que
// no cabe se marca `overflow` ⇒ el HUD ofrece "En el teléfono" (handoff).

import Foundation

public struct HUDCard: Sendable, Equatable {
    public var heading: String
    public var body: String
    public var overflow: Bool

    public init(heading: String, body: String, overflow: Bool = false) {
        self.heading = heading
        self.body = body
        self.overflow = overflow
    }
}

public enum HUDSummary {
    /// Máximo de caracteres que se dicen por TTS antes de remitir al teléfono.
    public static let spokenLimit = 280
    public static let phoneTail = "El resto está en tu teléfono."

    /// Quita el markdown que el HUD no puede pintar (no hay negritas ni listas).
    public static func plain(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line.removeFirst() }
            for bullet in ["- ", "* ", "• "] where line.hasPrefix(bullet) {
                line = String(line.dropFirst(bullet.count))
            }
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { lines.append(line) }
        }
        return lines.joined(separator: " ")
    }

    /// Divide en frases (., ?, !, …) conservando el signo, con la regla de
    /// `boundary` (la MISMA que usa la voz en vivo de las gafas).
    public static func sentences(_ text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var current = ""
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            guard boundary(chars, at: i) ?? true else { continue }
            let s = current.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { out.append(s) }
            current = ""
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    /// ¿Termina una frase en `chars[i]`? nil = aún no se sabe (falta la palabra
    /// siguiente: en un stream, esperar; en un texto completo, es el final).
    /// Solo corta un signo seguido de espacio ("1.250.000", "3.30" y las URLs
    /// quedan enteros). Tras un punto de abreviatura: las de título o dirección
    /// ("Sr.", "Dr.", "Av.", "apto.", "núm.") nunca cortan; "etc.", "aprox.",
    /// "p. ej." y la hora ("p. m.", "a. m.") cortan solo si sigue mayúscula.
    public static func boundary(_ chars: [Character], at i: Int) -> Bool? {
        let ch = chars[i]
        guard ".?!…".contains(ch) else { return false }
        if i + 1 < chars.count, !chars[i + 1].isWhitespace { return false }
        guard ch == "." else { return true }
        let word = wordBefore(chars, at: i)
        let previous = wordBefore(chars, at: i - word.count - 1, skippingSpaces: true)
        var rule = abbreviation(word)
        if rule == nil, ["a", "p"].contains(word) {
            let next = nextWord(chars, after: i)
            let patterns = word == "p" ? ["m.", "ej."] : ["m."]
            if patterns.contains(next.word) { return false }
            // La palabra siguiente llegó a medias ("m", "e", "ej") al final del
            // buffer: en un stream, aún no se sabe.
            if !next.complete, patterns.contains(where: { $0.hasPrefix(next.word) }) { return nil }
        }
        if rule == nil, word == "m", ["a.", "p."].contains(previous + ".") { rule = .beforeLowercase }
        if rule == nil, word == "ej", previous == "p" { rule = .beforeLowercase }
        switch rule {
        case nil: return true
        case .never: return false
        case .beforeLowercase:
            guard let next = nextCharacter(chars, after: i) else { return nil }
            return next.isUppercase
        }
    }

    enum AbbreviationRule { case never, beforeLowercase }

    static let neverCut: Set<String> = [
        "sr", "sra", "srta", "dr", "dra", "lic", "ing", "prof", "av", "cra", "cl", "tel", "apto",
        "núm", "pág", "dto", "cía", "vs", "mz", "ofi", "of",
    ]
    static let cutBeforeUppercase: Set<String> = ["etc", "aprox", "p.ej", "a.m", "p.m", "ej"]

    static func abbreviation(_ word: String) -> AbbreviationRule? {
        if neverCut.contains(word) { return .never }
        if cutBeforeUppercase.contains(word) { return .beforeLowercase }
        return nil
    }

    /// La palabra (en minúsculas, sin signos de apertura) que termina justo antes de `i`.
    private static func wordBefore(_ chars: [Character], at i: Int, skippingSpaces: Bool = false) -> String {
        var j = i - 1
        if skippingSpaces { while j >= 0, chars[j].isWhitespace { j -= 1 } }
        if skippingSpaces, j >= 0, chars[j] == "." { j -= 1 }
        var word: [Character] = []
        while j >= 0, !chars[j].isWhitespace {
            word.insert(chars[j], at: 0)
            j -= 1
        }
        return String(word).trimmingCharacters(in: CharacterSet(charactersIn: "(¿¡\"'")).lowercased()
    }

    private static func nextCharacter(_ chars: [Character], after i: Int) -> Character? {
        var j = i + 1
        while j < chars.count, chars[j].isWhitespace { j += 1 }
        return j < chars.count ? chars[j] : nil
    }

    /// La palabra que sigue a `i` (sin la puntuación que la cierra: "m.," y
    /// "m.)" cuentan como "m.") y si está completa (le sigue un espacio).
    private static func nextWord(_ chars: [Character], after i: Int) -> (word: String, complete: Bool) {
        var j = i + 1
        while j < chars.count, chars[j].isWhitespace { j += 1 }
        var word = ""
        while j < chars.count, !chars[j].isWhitespace {
            word.append(chars[j])
            j += 1
        }
        let trailing = CharacterSet(charactersIn: ",;:)]}»\"'”’!?")
        let bare = String(String.UnicodeScalarView(word.unicodeScalars.reversed().drop { trailing.contains($0) }
            .reversed()))
        return (bare.lowercased(), j < chars.count)
    }

    /// Recorta a `limit` en frontera de palabra, con "…".
    public static func clip(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let hard = String(text.prefix(max(1, limit - 1)))
        let cut = hard.lastIndex(of: " ").map { String(hard[..<$0]) } ?? hard
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "…"
    }

    /// Gist de la respuesta: primera frase → heading; el resto → body.
    public static func card(from reply: String) -> HUDCard {
        let text = plain(reply)
        let parts = sentences(text)
        guard let first = parts.first else {
            return HUDCard(heading: "Listo.", body: "", overflow: false)
        }
        var heading = first
        var rest = parts.dropFirst().joined(separator: " ")
        var overflow = false
        if heading.count > HUDValidator.headingLimit {
            // La primera frase no cabe como título: título recortado, frase completa al body.
            rest = rest.isEmpty ? first : first + " " + rest
            heading = clip(first, HUDValidator.headingLimit)
        }
        if rest.count > HUDValidator.bodyLimit {
            overflow = true
            rest = clip(rest, HUDValidator.bodyLimit)
        }
        return HUDCard(heading: heading, body: rest, overflow: overflow)
    }

    /// Texto a decir por los parlantes: la respuesta si es corta; si no, las
    /// primeras frases que quepan + remisión al teléfono.
    public static func spoken(from reply: String) -> String {
        let text = plain(reply)
        guard text.count > spokenLimit else { return text }
        var said = ""
        for sentence in sentences(text) {
            let next = said.isEmpty ? sentence : said + " " + sentence
            if next.count > spokenLimit { break }
            said = next
        }
        if said.isEmpty { said = clip(text, spokenLimit) }
        return said + " " + phoneTail
    }
}
