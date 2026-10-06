// ChatMarkdown.swift — el texto del asistente → BLOQUES renderizables en el chat
// del teléfono (campo #4 y batch 5b #2: títulos con "##" y tablas crudas).
// Parser propio, determinista y por líneas:
//   · encabezados `#`/`##`/`###` (sin mostrar los `#`), párrafos, listas con
//     viñetas o numeradas (anidadas 1 nivel), tablas `| a | b |` + separador,
//     bloques de código ```, citas `>` y separadores `---`;
//   · dentro de cada bloque, markdown INLINE (negrilla, cursiva, código, links)
//     con `.inlineOnlyPreservingWhitespace`.
// Streaming: se parsea el mensaje COMPLETO acumulado en cada delta. Un fence sin
// cerrar ya es código; una tabla sin su fila separadora todavía es texto; una
// fila a medio llegar se pinta con las celdas que ya tiene. Nunca lanza.

import Foundation

public enum ChatMarkdown {
    public struct ListItem: Sendable, Equatable {
        /// "•" o "1." (el número que escribió el modelo).
        public var marker: String
        public var text: AttributedString
        /// Un nivel de anidación.
        public var children: [ListItem]

        public init(marker: String, text: AttributedString, children: [ListItem] = []) {
            self.marker = marker
            self.text = text
            self.children = children
        }
    }

    public enum Alignment: Sendable, Equatable {
        case leading, center, trailing
    }

    public struct Table: Sendable, Equatable {
        public var header: [AttributedString]
        public var rows: [[AttributedString]]
        public var alignments: [Alignment]

        public var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }
    }

    public enum Block: Sendable, Equatable {
        case paragraph(AttributedString)
        case heading(level: Int, AttributedString)
        case list(ordered: Bool, items: [ListItem])
        case table(Table)
        case code(String, language: String?)
        case quote(AttributedString)
        case rule
    }

    // MARK: - Parser

    public static func blocks(_ source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [Block] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var list: (ordered: Bool, items: [RawItem])?
        var index = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append(.paragraph(inline(text))) }
            paragraph.removeAll()
        }
        func flushQuote() {
            let text = quote.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append(.quote(inline(text))) }
            quote.removeAll()
        }
        func flushList() {
            if let current = list, !current.items.isEmpty {
                out.append(.list(ordered: current.ordered, items: current.items.map(\.rendered)))
            }
            list = nil
        }
        func flushAll() { flushParagraph(); flushQuote(); flushList() }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Código: hasta el fence de cierre (o el final, si aún llega por stream).
            if trimmed.hasPrefix("```") {
                flushAll()
                let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                out.append(.code(code.joined(separator: "\n"), language: tag.isEmpty ? nil : tag))
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                index += 1
                continue
            }

            if let heading = heading(trimmed) {
                flushAll()
                out.append(.heading(level: heading.level, inline(heading.text)))
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushAll()
                out.append(.rule)
                index += 1
                continue
            }

            // Tabla: fila de encabezado + fila separadora `|---|:--:|`.
            if trimmed.contains("|"), index + 1 < lines.count,
               let alignments = separatorAlignments(lines[index + 1]) {
                flushAll()
                let header = cells(trimmed)
                var rows: [[AttributedString]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(cells(row).map { inline($0) })
                    index += 1
                }
                out.append(.table(Table(header: header.map { inline($0) }, rows: rows, alignments: alignments)))
                continue
            }

            if let quoted = quoteLine(trimmed) {
                flushParagraph(); flushList()
                quote.append(quoted)
                index += 1
                continue
            }

            if let item = listItem(line) {
                flushParagraph(); flushQuote()
                if list == nil || list?.ordered != item.ordered && item.indent < 2 {
                    flushList()
                    list = (item.ordered, [])
                }
                let entry = RawItem(marker: item.marker, text: item.text)
                if item.indent >= 2, var current = list, !current.items.isEmpty {
                    current.items[current.items.count - 1].children.append(entry)
                    list = current
                } else {
                    list?.items.append(entry)
                }
                index += 1
                continue
            }

            // Continuación de un ítem de lista (línea sangrada sin marcador).
            if var current = list, !current.items.isEmpty, line.hasPrefix("  ") {
                let last = current.items.count - 1
                if current.items[last].children.isEmpty {
                    current.items[last].text += "\n" + trimmed
                } else {
                    current.items[last].children[current.items[last].children.count - 1].text += "\n" + trimmed
                }
                list = current
                index += 1
                continue
            }

            flushQuote(); flushList()
            paragraph.append(line)
            index += 1
        }
        flushAll()
        return out
    }

    // MARK: - Piezas

    static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        // "##Título" sin espacio (los modelos lo escriben a veces) también es
        // título si sigue una letra; con un solo "#" no ("#hashtag").
        let glued = hashes >= 2 && (rest.first?.isLetter ?? false)
        guard rest.isEmpty || rest.first == " " || glued else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }   // "## Título ##"
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func quoteLine(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix(">") else { return nil }
        let rest = trimmed.dropFirst()
        return String(rest.first == " " ? rest.dropFirst() : rest)
    }

    static func listItem(_ line: String) -> (indent: Int, ordered: Bool, marker: String, text: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            return (indent, false, "•", body.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let after = body.dropFirst(digits.count)
        guard let punct = after.first, punct == "." || punct == ")", after.dropFirst().first == " " else { return nil }
        return (indent, true, "\(digits).", after.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    /// `|---|:--:|---:|` → alineaciones; nil si la línea no es separadora.
    static func separatorAlignments(_ line: String) -> [Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix(":") || trimmed.hasPrefix("-") else {
            return nil
        }
        let parts = cells(trimmed)
        guard !parts.isEmpty else { return nil }
        var out: [Alignment] = []
        for part in parts {
            let cell = part.trimmingCharacters(in: .whitespaces)
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): out.append(.center)
            case (false, true): out.append(.trailing)
            default: out.append(.leading)
            }
        }
        return out
    }

    /// "| a | b |" → ["a", "b"] (respeta `\|` escapado).
    static func cells(_ row: String) -> [String] {
        var trimmed = row.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var out: [String] = []
        var current = ""
        var escaped = false
        for ch in trimmed {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "|" { out.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(ch)
        }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out
    }

    /// Ítem crudo mientras se parsea (el inline se aplica al cerrar la lista).
    struct RawItem {
        var marker: String
        var text: String
        var children: [RawItem] = []

        var rendered: ListItem {
            ListItem(marker: marker, text: inline(text), children: children.map(\.rendered))
        }
    }

    /// Markdown inline; si no parsea, el texto tal cual.
    public static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                             failurePolicy: .throwError)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
