// SpokenStream.swift — TTS por oración mientras la respuesta llega (campo #7b).
// Antes el TTS esperaba la respuesta COMPLETA del turno; ahora la primera
// oración se dice apenas está completa en el stream y las siguientes se
// encolan. Puro:
//   · StreamingSentenceSegmenter: deltas → oraciones completas (texto plano,
//     sin markdown), cada una una sola vez y en orden;
//   · SpokenScript: aplica el presupuesto de voz (HUDSummary.spokenLimit +
//     remisión al teléfono, misma política que HUDSummary.spoken) y lleva los
//     OFFSETS de cada utterance en el texto hablado completo — el karaoke
//     recibe rangos POR utterance y los traduce a rangos absolutos.

import Foundation

public struct StreamingSentenceSegmenter: Sendable, Equatable {
    private var raw = ""
    /// Caracteres del texto plano ya emitidos.
    private var emitted = 0

    public init() {}

    /// Un delta del stream → las oraciones que quedaron completas (terminador
    /// seguido de espacio: "9.30" no corta).
    public mutating func feed(_ delta: String) -> [String] {
        raw += delta
        let plain = Array(HUDSummary.plain(raw))
        var out: [String] = []
        var start = emitted
        var i = emitted
        while i + 1 < plain.count {
            if ".?!…".contains(plain[i]), plain[i + 1].isWhitespace {
                let sentence = String(plain[start...i]).trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty { out.append(sentence) }
                start = i + 1
            }
            i += 1
        }
        emitted = start
        return out
    }

    /// Fin del stream: lo que quede es la última oración.
    public mutating func finish() -> [String] {
        let plain = Array(HUDSummary.plain(raw))
        guard emitted < plain.count else { return [] }
        let tail = String(plain[emitted...]).trimmingCharacters(in: .whitespaces)
        emitted = plain.count
        return tail.isEmpty ? [] : [tail]
    }
}

public struct SpokenScript: Sendable, Equatable {
    public let limit: Int
    public private(set) var utterances: [String] = []
    public private(set) var truncated = false
    public private(set) var finished = false
    private var segmenter = StreamingSentenceSegmenter()

    public init(limit: Int = HUDSummary.spokenLimit) {
        self.limit = limit
    }

    /// Un texto ya completo, dicho como UNA utterance (camino sin stream).
    public init(whole text: String) {
        self.limit = .max
        if !text.isEmpty { utterances = [text] }
        finished = true
    }

    /// El texto hablado completo: las utterances unidas por un espacio.
    public var text: String { utterances.joined(separator: " ") }

    /// Delta del stream → las utterances NUEVAS a encolar en el TTS.
    public mutating func feed(_ delta: String) -> [String] {
        guard !finished else { return [] }
        return segmenter.feed(delta).compactMap { admit($0) }
    }

    /// Fin del stream → la última oración (si cabe) + la remisión al teléfono.
    public mutating func finish() -> [String] {
        guard !finished else { return [] }
        var out = segmenter.finish().compactMap { admit($0) }
        finished = true
        if truncated {
            utterances.append(HUDSummary.phoneTail)
            out.append(HUDSummary.phoneTail)
        }
        return out
    }

    /// Offset UTF-16 de la utterance `index` en `text`.
    public func offset(of index: Int) -> Int {
        utterances.prefix(max(0, min(index, utterances.count))).reduce(0) { $0 + ($1 as NSString).length + 1 }
    }

    /// Rango que reporta el sintetizador para la utterance `index` → rango en `text`.
    public func absolute(_ index: Int, _ range: NSRange) -> NSRange {
        guard range.location != NSNotFound else { return range }
        return NSRange(location: offset(of: index) + range.location, length: range.length)
    }

    private mutating func admit(_ sentence: String) -> String? {
        guard !truncated else { return nil }
        let said = text
        let next = said.isEmpty ? sentence : said + " " + sentence
        guard next.count > limit else {
            utterances.append(sentence)
            return sentence
        }
        truncated = true
        guard said.isEmpty else { return nil }
        let clipped = HUDSummary.clip(sentence, limit)
        utterances.append(clipped)
        return clipped
    }
}
