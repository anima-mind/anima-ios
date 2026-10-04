// HUDSpokenPager.swift — "karaoke por ventana" (campo #3). Las respuestas
// largas se cortaban con "…" y la card no seguía al TTS. El pager parte el texto
// HABLADO en ventanas que caben en el body de la card (presupuesto del HUD,
// cortes por oración o palabra, "…" solo al inicio si hay texto anterior) y,
// con el rango que el sintetizador está pronunciando, decide la ventana
// visible. Histéresis: solo cambia de página cuando el rango hablado SALE de la
// ventana actual — nada de re-render por palabra. Puro.

import Foundation

public struct HUDSpokenPager: Sendable, Equatable {
    public struct Page: Sendable, Equatable {
        /// Rango UTF-16 en el texto hablado (el que reporta AVSpeechSynthesizer).
        public var range: NSRange
        /// Lo que se muestra (con "…" inicial si hay texto anterior).
        public var text: String
    }

    public static let ellipsis = "…"

    public let pages: [Page]
    public private(set) var current = 0

    /// `heading`: si el texto hablado empieza con el título de la card, las
    /// ventanas arrancan DESPUÉS (el título ya está en pantalla).
    public init(_ text: String, after heading: String = "", budget: Int = HUDValidator.bodyLimit) {
        pages = Self.paginate(text, after: heading, budget: max(8, budget))
    }

    /// La ventana visible ("" si no hay nada que mostrar tras el título).
    public var window: String { pages.isEmpty ? "" : pages[current].text }

    public var windows: [String] { pages.map(\.text) }

    /// El sintetizador va pronunciando `spoken`. Devuelve la nueva ventana SOLO
    /// si cambió de página; nil mientras el rango siga dentro de la actual.
    public mutating func advance(to spoken: NSRange) -> String? {
        guard !pages.isEmpty, spoken.location != NSNotFound else { return nil }
        if NSLocationInRange(spoken.location, pages[current].range) { return nil }
        let target = pages.lastIndex { $0.range.location <= spoken.location } ?? 0
        guard target != current else { return nil }
        current = target
        return pages[current].text
    }

    // MARK: - Paginación

    static func paginate(_ text: String, after heading: String, budget: Int) -> [Page] {
        var start = text.startIndex
        if !heading.isEmpty, text.hasPrefix(heading) {
            start = text.index(start, offsetBy: heading.count)
        }
        start = skipSpaces(text, from: start)
        guard start < text.endIndex else { return [] }

        // Texto corto (y sin título que saltar): una sola ventana, idéntica.
        if start == text.startIndex, text.count <= budget {
            return [Page(range: NSRange(text.startIndex..<text.endIndex, in: text), text: text)]
        }

        var pages: [Page] = []
        while start < text.endIndex {
            let prefix = pages.isEmpty ? "" : ellipsis
            let available = budget - prefix.count
            let rest = text[start...]
            var end: String.Index
            if rest.count <= available {
                end = text.endIndex
            } else {
                end = cut(text, from: start, available: available)
            }
            var trimmed = end
            while trimmed > start, text[text.index(before: trimmed)].isWhitespace { trimmed = text.index(before: trimmed) }
            pages.append(Page(range: NSRange(start..<trimmed, in: text), text: prefix + text[start..<trimmed]))
            start = skipSpaces(text, from: end)
        }
        return pages
    }

    /// Dónde cortar una ventana de `available` caracteres: tras el último fin de
    /// oración (si deja la ventana al menos a medias), si no antes de la última
    /// palabra que no cabe, y como último recurso a la fuerza.
    static func cut(_ text: String, from start: String.Index, available: Int) -> String.Index {
        let limit = text.index(start, offsetBy: available)
        let half = text.index(start, offsetBy: available / 2)
        var sentenceEnd: String.Index?
        var lastSpace: String.Index?
        var i = start
        while i < limit {
            let next = text.index(after: i)
            let ch = text[i]
            if ".?!…".contains(ch), next <= limit, next == text.endIndex || text[next].isWhitespace, next >= half {
                sentenceEnd = next
            }
            if ch.isWhitespace, i > start { lastSpace = i }
            i = next
        }
        if limit < text.endIndex, text[limit].isWhitespace { lastSpace = limit }
        return sentenceEnd ?? lastSpace ?? limit
    }

    static func skipSpaces(_ text: String, from index: String.Index) -> String.Index {
        var i = index
        while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
        return i
    }
}
