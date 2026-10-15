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

    /// Divide en frases (., ?, !, …) conservando el signo. Solo corta si al
    /// signo le sigue un espacio (o el final): "1.250.000", "3.30" y
    /// "anima.app/x" quedan enteros; "..." y "?!" van juntos; y un punto tras
    /// una abreviatura común ("Sr.", "p. m.", "etc.") no corta.
    public static func sentences(_ text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var current = ""
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            guard ".?!…".contains(ch) else { continue }
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if let next, !next.isWhitespace { continue }
            if ch == ".", isAbbreviation(current) { continue }
            let s = current.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { out.append(s) }
            current = ""
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    static let abbreviations: Set<String> = [
        "sr", "sra", "srta", "dr", "dra", "lic", "ing", "prof", "etc", "ej", "p.ej", "aprox", "núm",
        "pág", "av", "cra", "cl", "tel", "a", "p", "m", "a.m", "p.m", "vs", "dto", "cía",
    ]

    /// ¿La palabra que termina en este punto es una abreviatura?
    private static func isAbbreviation(_ current: String) -> Bool {
        let word = current.dropLast().split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "(¿¡\"'")).lowercased()
        return abbreviations.contains(bare)
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
