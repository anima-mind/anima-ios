// ChatMarkdown.swift — el texto del asistente → segmentos renderizables en el
// chat del teléfono (campo #4: la negrilla salía con asteriscos). Puro:
//   · prosa → markdown INLINE (negrilla, cursiva, código, links) con
//     `.inlineOnlyPreservingWhitespace`: seguro para streaming y conserva los
//     saltos de línea;
//   · bloques ``` → segmento de código aparte (vista monoespaciada). Un fence
//     sin cerrar (llegando por stream) ya es bloque de código: no parpadea al
//     cerrarse.
// Se parsea el mensaje COMPLETO acumulado en cada delta, nunca por fragmento;
// si el parse falla, la prosa degrada en silencio a texto plano.

import Foundation

public enum ChatMarkdown {
    public enum Segment: Sendable, Equatable {
        case text(AttributedString)
        case code(String, language: String?)
    }

    public static func segments(_ source: String) -> [Segment] {
        var out: [Segment] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var language: String?
        var inCode = false

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.text(inline(text))) }
            prose.removeAll()
        }

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    out.append(.code(code.joined(separator: "\n"), language: language))
                    code.removeAll()
                    inCode = false
                } else {
                    flushProse()
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                    inCode = true
                }
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode {
            out.append(.code(code.joined(separator: "\n"), language: language))
        } else {
            flushProse()
        }
        return out
    }

    /// Markdown inline; si no parsea, el texto tal cual.
    public static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                             failurePolicy: .throwError)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
