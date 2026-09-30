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

    /// Divide en frases (., ?, !, …) conservando el signo.
    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".?!…".contains(ch) {
                let s = current.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { out.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out
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
