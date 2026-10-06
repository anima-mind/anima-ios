// MarkdownMessage.swift — los bloques de ChatMarkdown en el chat: encabezados
// con jerarquía (sin "#"), listas con su marcador, tablas como grilla (encabezado
// en label, hairline entre filas, scroll horizontal si no cabe), código
// monoespaciado sobre surface, citas con regla accent y separadores.

#if canImport(SwiftUI)
import SwiftUI

struct MarkdownMessage: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ChatMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
    }
}

struct MarkdownBlockView: View {
    let block: ChatMarkdown.Block

    var body: some View {
        switch block {
        case .paragraph(let text):
            prose(text, font: Theme.Type_.body)
        case .heading(let level, let text):
            prose(text, font: Self.font(heading: level))
                .padding(.top, level <= 2 ? 6 : 2)
                .accessibilityAddTraits(.isHeader)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listItem(item, ordered: ordered)
                    ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                        listItem(child, ordered: child.marker != "•").padding(.leading, 20)
                    }
                }
            }
        case .table(let table):
            MarkdownTable(table: table)
        case .code(let code, _):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.Colors.text)
                    .textSelection(.enabled)
                    .padding(Theme.Space.cardPad)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(Theme.Colors.accent).frame(width: 2)
                prose(text, font: Theme.Type_.body, color: Theme.Colors.textMuted)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle().fill(Theme.Colors.border).frame(height: Theme.Stroke.hairline)
                .padding(.vertical, 4)
        }
    }

    static func font(heading level: Int) -> Font {
        switch level {
        case 1: return Theme.Type_.heading1
        case 2: return Theme.Type_.heading2
        default: return Theme.Type_.heading3
        }
    }

    private func prose(_ text: AttributedString, font: Font, color: Color = Theme.Colors.text) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .tint(Theme.Colors.accentText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func listItem(_ item: ChatMarkdown.ListItem, ordered: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.marker)
                .font(ordered ? Theme.Type_.tabular(Theme.Type_.body) : Theme.Type_.body)
                .foregroundStyle(ordered ? Theme.Colors.textMuted : Theme.Colors.accent)
                .frame(minWidth: ordered ? 18 : 10, alignment: .trailing)
            prose(item.text, font: Theme.Type_.body)
        }
    }
}

/// Tabla del markdown: columnas con ancho por contenido (acotado), celdas que
/// envuelven, encabezado en `label`, hairline entre filas; scroll horizontal
/// solo si no cabe.
struct MarkdownTable: View {
    let table: ChatMarkdown.Table
    static let minColumn: CGFloat = 64
    static let maxColumn: CGFloat = 220
    static let cellPadH: CGFloat = 10
    static let cellPadV: CGFloat = 8
    static let charWidth: CGFloat = 8.5

    var body: some View {
        let widths = Self.columnWidths(table)
        // Si cabe, ocupa el ancho del mensaje (el sobrante se reparte entre columnas) y
        // se lee entero con VoiceOver; si no, scroll horizontal.
        ViewThatFits(in: .horizontal) {
            grid(widths, stretch: true)
            ScrollView(.horizontal, showsIndicators: false) { grid(widths, stretch: false) }
        }
        .accessibilityIdentifier("chat.markdown.table")
    }

    private func grid(_ widths: [CGFloat], stretch: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row(table.header, widths: widths, header: true, stretch: stretch)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                Rectangle().fill(Theme.Colors.border).frame(height: Theme.Stroke.hairline)
                row(cells, widths: widths, header: false, stretch: stretch)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func row(_ cells: [AttributedString], widths: [CGFloat], header: Bool, stretch: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<widths.count, id: \.self) { column in
                let text = column < cells.count ? cells[column] : AttributedString("")
                let last = column == widths.count - 1
                cell(text, header: header, alignment: column < table.alignments.count ? table.alignments[column] : .leading)
                    .frame(minWidth: widths[column], maxWidth: stretch ? .infinity : widths[column],
                           alignment: Self.frameAlignment(column, table))
                if !last {
                    Rectangle().fill(Theme.Colors.border.opacity(0.6)).frame(width: Theme.Stroke.hairline)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(header ? Theme.Colors.tint : Color.clear)
    }

    @ViewBuilder
    private func cell(_ text: AttributedString, header: Bool, alignment: ChatMarkdown.Alignment) -> some View {
        Group {
            if header {
                Text(String(text.characters).uppercased())
                    .font(Theme.Type_.label)
                    .kerning(0.66)
                    .foregroundStyle(Theme.Colors.textMuted)
            } else {
                Text(text)
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.text)
                    .tint(Theme.Colors.accentText)
            }
        }
        .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Self.cellPadH)
        .padding(.vertical, Self.cellPadV)
    }

    static func frameAlignment(_ column: Int, _ table: ChatMarkdown.Table) -> SwiftUI.Alignment {
        guard column < table.alignments.count else { return .topLeading }
        switch table.alignments[column] {
        case .leading: return .topLeading
        case .center: return .top
        case .trailing: return .topTrailing
        }
    }

    /// Ancho por columna ≈ el texto más largo (≈8.5 pt por carácter a 13 pt),
    /// acotado a [64, 220]: lo largo envuelve en vez de ensanchar la tabla.
    static func columnWidths(_ table: ChatMarkdown.Table) -> [CGFloat] {
        (0..<table.columnCount).map { column in
            let lengths = ([table.header] + table.rows).map { row -> Int in
                column < row.count ? row[column].characters.count : 0
            }
            let longest = CGFloat(lengths.max() ?? 0)
            return min(max(longest * charWidth + cellPadH * 2, minColumn), maxColumn)
        }
    }
}
#endif
