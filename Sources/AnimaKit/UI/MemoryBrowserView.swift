// MemoryBrowserView.swift — inspección del brain (§6 Fase 2): lista de memorias
// con contenido, tipo, confianza, estado (viva / invalidada + razón) y último
// uso; filtro por texto; detalle con la cadena de reconsolidaciones; e invalidar
// manual con razón. Dark-only, tokens de Theme (acento solo como línea).

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class MemoryBrowserViewModel: ObservableObject {
    public struct Item: Identifiable, Sendable {
        public let id: MemoryID
        public var content: String
        public var kind: MemoryKind
        public var confidence: Double
        public var isValid: Bool
        public var invalidationReason: String?
        public var lastUsed: Date?
        public var createdAt: Date
    }

    @Published public var items: [Item] = []
    @Published public var filter: String = ""
    @Published public var selected: MemoryDetail?

    private let brain: Brain

    public init(brain: Brain) {
        self.brain = brain
    }

    public func load() async {
        let records = (try? await brain.browse(filter: filter.isEmpty ? nil : filter)) ?? []
        var out: [Item] = []
        for record in records {
            let lastUsed = try? await brain.lastUsed(record.id)
            out.append(Item(id: record.id, content: record.content, kind: record.kind,
                            confidence: record.confidence, isValid: record.isValid,
                            invalidationReason: record.invalidationReason,
                            lastUsed: lastUsed ?? nil, createdAt: record.createdAt))
        }
        items = out
    }

    public func openDetail(_ id: MemoryID) async {
        let chain = (try? await brain.revisionChain(id)) ?? []
        selected = MemoryDetail(id: id, chain: chain)
    }

    public func invalidate(_ id: MemoryID, reason: String) async {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        try? await brain.invalidate(id: id, reason: text)
        selected = nil
        await load()
    }
}

public struct MemoryDetail: Identifiable, Sendable {
    public let id: MemoryID
    public var chain: [MemoryRecord]
}

public struct MemoryBrowserView: View {
    @ObservedObject private var model: MemoryBrowserViewModel

    public init(model: MemoryBrowserViewModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            Theme.Colors.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                filterField
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.stack) {
                        ForEach(model.items) { row($0) }
                    }
                    .padding(.horizontal, Theme.Space.screenInset)
                }
            }
            .padding(.top, Theme.Space.screenInset)
        }
        .task { await model.load() }
        .sheet(item: $model.selected) { detail in
            MemoryDetailSheet(detail: detail) { id, reason in
                Task { await model.invalidate(id, reason: reason) }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var filterField: some View {
        TextField("Buscar memorias", text: $model.filter)
            .font(Theme.Type_.body)
            .foregroundStyle(Theme.Colors.text)
            .padding(Theme.Space.cardPad)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
            .padding(.horizontal, Theme.Space.screenInset)
            .onSubmit { Task { await model.load() } }
    }

    private func row(_ item: MemoryBrowserViewModel.Item) -> some View {
        Button {
            Task { await model.openDetail(item.id) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.content)
                    .font(Theme.Type_.body)
                    .foregroundStyle(item.isValid ? Theme.Colors.text : Theme.Colors.textFaint)
                    .strikethrough(!item.isValid, color: Theme.Colors.textFaint)
                    .multilineTextAlignment(.leading)
                HStack(spacing: Theme.Space.stack) {
                    tag(item.kind.rawValue)
                    tag(String(format: "conf %.1f", item.confidence))
                    if !item.isValid { tag("invalidada") }
                    Spacer()
                    if let lastUsed = item.lastUsed {
                        Text(Self.relative(lastUsed))
                            .font(Theme.Type_.meta)
                            .foregroundStyle(Theme.Colors.textFaint)
                    }
                }
                if !item.isValid, let reason = item.invalidationReason {
                    Text(reason)
                        .font(Theme.Type_.meta)
                        .foregroundStyle(Theme.Colors.textFaint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.cardPad)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(Theme.Colors.surface)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline)))
        }
        .buttonStyle(.plain)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(Theme.Type_.meta)
            .foregroundStyle(Theme.Colors.textMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.Colors.tint))
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct MemoryDetailSheet: View {
    let detail: MemoryDetail
    let onInvalidate: (MemoryID, String) -> Void
    @State private var reason: String = ""

    var body: some View {
        ZStack {
            Theme.Colors.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
                    Text("Historial de reconsolidaciones")
                        .font(Theme.Type_.label)
                        .textCase(.uppercase)
                        .kerning(0.66)
                        .foregroundStyle(Theme.Colors.textMuted)
                    ForEach(detail.chain) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.content)
                                .font(Theme.Type_.body)
                                .foregroundStyle(record.isValid ? Theme.Colors.text : Theme.Colors.textFaint)
                                .strikethrough(!record.isValid, color: Theme.Colors.textFaint)
                            if let invReason = record.invalidationReason {
                                Text("invalidada: \(invReason)")
                                    .font(Theme.Type_.meta)
                                    .foregroundStyle(Theme.Colors.textFaint)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.cardPad)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                    }

                    VStack(alignment: .leading, spacing: Theme.Space.stack) {
                        Text("Invalidar manualmente")
                            .font(Theme.Type_.label)
                            .textCase(.uppercase)
                            .kerning(0.66)
                            .foregroundStyle(Theme.Colors.textMuted)
                        TextField("Razón", text: $reason)
                            .font(Theme.Type_.body)
                            .foregroundStyle(Theme.Colors.text)
                            .padding(Theme.Space.cardPad)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                        Button("Invalidar") { onInvalidate(detail.id, reason) }
                            .font(Theme.Type_.secondary)
                            .foregroundStyle(Theme.Colors.accent)
                            .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(Theme.Space.screenInset)
            }
        }
    }
}
#endif
