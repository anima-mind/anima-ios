// ICURegex.swift — regex precompiladas (ICU, NSRegularExpression) para los
// caminos calientes. Medido en el CI de #45 (runner de 3 núcleos): la `Regex`
// de Swift se reconstruía en cada llamada y, sincrónica en el pool cooperativo,
// dejaba sin hilos a la suite (eventually de 10 s vencidos). Toda regex de
// `Sources/` va por aquí como `static let`; scripts/check-no-swift-regex.sh
// falla si vuelve la de Swift.

import Foundation

/// Una regex compilada UNA vez. NSRegularExpression es inmutable y segura entre hilos.
public struct ICURegex: @unchecked Sendable {
    public let regex: NSRegularExpression

    public init(_ pattern: String, caseInsensitive: Bool = false) {
        // El patrón es una constante del código: si no compila es un bug del programador.
        regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    public func firstMatch(in text: String) -> ICUMatch? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).map { ICUMatch(text: text, result: $0) }
    }

    public func matches(in text: String) -> [ICUMatch] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { ICUMatch(text: text, result: $0) }
    }

    public func contains(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Reemplaza cada coincidencia por `replacement` LITERAL (sin plantillas $1).
    public func replacing(in text: String, with replacement: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                       withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    /// Reemplaza con plantilla ICU ("$1 $2").
    public func replacing(in text: String, template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

/// Una coincidencia: el rango completo y los grupos como `Substring` del texto.
public struct ICUMatch {
    public let text: String
    public let result: NSTextCheckingResult

    /// El rango completo en el texto.
    public var range: Range<String.Index> { Range(result.range, in: text) ?? text.startIndex..<text.startIndex }

    public var whole: Substring { text[range] }

    /// El grupo `index` (1…), o nil si no participó.
    public subscript(_ index: Int) -> Substring? {
        guard index < result.numberOfRanges else { return nil }
        let nsRange = result.range(at: index)
        guard nsRange.location != NSNotFound, let r = Range(nsRange, in: text) else { return nil }
        return text[r]
    }

    /// El grupo con nombre, o nil.
    public subscript(_ name: String) -> Substring? {
        let nsRange = result.range(withName: name)
        guard nsRange.location != NSNotFound, let r = Range(nsRange, in: text) else { return nil }
        return text[r]
    }
}
