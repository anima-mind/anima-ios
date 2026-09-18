// Embedder.swift — wrapper de NLEmbedding (embeddings de oración on-device,
// §5.3). El idioma se detecta por memoria con NLLanguageRecognizer; los espacios
// de embedding por idioma no son comparables, así que cada vector lleva su
// `rev` (modelo+idioma+dim) y el coseno solo compara vectores del mismo rev.
//
// Fallback determinista: si el asset de NLEmbedding no está disponible (CI de
// macOS puede no tenerlo), se usa un pseudo-embedding hash-based MARCADO como
// fallback — los tests no dependen del asset. El fallback es bag-of-words
// hasheado y L2-normalizado: no es semántico de verdad, pero es estable.

import Foundation
import NaturalLanguage

public final class Embedder {
    public static let fallbackRev = "fallback-hash-v1"
    public static let fallbackDim = 256

    /// Un vector con su rev de procedencia. Solo se comparan vectores del mismo rev.
    public struct Vector: Sendable, Equatable {
        public var values: [Float]
        public var rev: String
    }

    private var cache: [String: NLEmbedding] = [:]
    private let forceFallback: Bool

    /// `forceFallback` obliga el pseudo-embedding determinista (tests: no dependen
    /// del asset de NLEmbedding, que en producción sí se usa).
    public init(forceFallback: Bool = false) {
        self.forceFallback = forceFallback
    }

    public func embed(_ text: String) -> Vector {
        let language = detectLanguage(text)
        if !forceFallback,
           let emb = sentenceEmbedding(for: language),
           let raw = emb.vector(for: text) {
            return Vector(values: raw.map { Float($0) },
                          rev: "nl-\(language.rawValue)-\(emb.dimension)")
        }
        return Vector(values: Self.hashEmbed(text), rev: Self.fallbackRev)
    }

    private func detectLanguage(_ text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage ?? .spanish
    }

    private func sentenceEmbedding(for language: NLLanguage) -> NLEmbedding? {
        if let cached = cache[language.rawValue] { return cached }
        guard let emb = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        cache[language.rawValue] = emb
        return emb
    }

    // MARK: - Fallback determinista

    static func hashEmbed(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: fallbackDim)
        for token in tokenize(text) {
            let slot = Int(stableHash(token) % UInt64(fallbackDim))
            v[slot] += 1
        }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { for i in v.indices { v[i] /= norm } }
        return v
    }

    /// Tokeniza sin diacríticos, minúsculas, tokens de ≥3 caracteres (descarta
    /// stopwords cortas como "en"/"la"/"de" que inflarían el solapamiento).
    static func tokenize(_ text: String) -> [String] {
        let folded = text
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
            .lowercased()
        return folded
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }
    }

    /// FNV-1a de 64 bits — hash estable entre corridas (String.hashValue no lo es).
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }
}

// MARK: - [Float] <-> Data (BLOB little-endian)

extension Array where Element == Float {
    var floatData: Data { withUnsafeBytes { Data($0) } }

    init(floatData data: Data) {
        let count = data.count / MemoryLayout<Float>.size
        var arr = [Float](repeating: 0, count: count)
        _ = arr.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        self = arr
    }
}
