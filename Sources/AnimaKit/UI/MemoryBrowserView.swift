// MemoryBrowserView.swift — inspección del brain (§6 Fase 2, batch 5b #10): por
// defecto SOLO las memorias activas, con su origen legible ("Noche #3 ·
// destilado", "Chat"), tipo y confianza en español y la fecha; las invalidadas
// se despliegan aparte ("Mostrar invalidadas (N)") y se pueden vaciar de la UI
// (bi-temporal: quedan en la base marcadas). Detalle con origen, historial de
// reconsolidaciones e "Invalidar" como botón real con razón opcional.

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class MemoryBrowserViewModel: ObservableObject {
    public struct Item: Identifiable, Sendable, Equatable {
        public let id: MemoryID
        public var content: String
        public var kind: MemoryKind
        public var confidence: Double
        public var isValid: Bool
        public var invalidationReason: String?
        public var lastUsed: Date?
        public var createdAt: Date
        /// "Noche #3 · destilado" | "Chat" | "origen desconocido".
        public var origin: String

        var invalidatedKey: String { "invalidated-\(id)" }
    }

    @Published public var items: [Item] = []
    @Published public var filter: String = ""
    @Published public var selected: MemoryDetail?
    @Published public var showInvalidated = false

    public static let defaultReason = "invalidada por el dueño"

    private let brain: Brain
    public var dates = AnimaDateText()

    public init(brain: Brain) {
        self.brain = brain
    }

    public var active: [Item] { items.filter(\.isValid) }
    public var invalidated: [Item] { items.filter { !$0.isValid } }

    public func load() async {
        let records = (try? await brain.browse(filter: filter.isEmpty ? nil : filter)) ?? []
        var out: [Item] = []
        for record in records {
            let lastUsed = try? await brain.lastUsed(record.id)
            out.append(Item(id: record.id, content: record.content, kind: record.kind,
                            confidence: record.confidence, isValid: record.isValid,
                            invalidationReason: record.invalidationReason,
                            lastUsed: lastUsed ?? nil, createdAt: record.createdAt,
                            origin: Self.origin(record)))
        }
        items = out
    }

    public func openDetail(_ id: MemoryID) async {
        let chain = (try? await brain.revisionChain(id)) ?? []
        guard let item = items.first(where: { $0.id == id }) else {
            selected = MemoryDetail(id: id, chain: chain)
            return
        }
        selected = MemoryDetail(id: id, chain: chain, content: item.content, origin: item.origin,
                                date: dates.fullDate(item.createdAt, now: Date()), isValid: item.isValid)
    }

    /// Razón OPCIONAL: vacía ⇒ "invalidada por el dueño".
    public func invalidate(_ id: MemoryID, reason: String = "") async {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        try? await brain.invalidate(id: id, reason: text.isEmpty ? Self.defaultReason : text)
        selected = nil
        await load()
    }

    /// "Vaciar invalidadas": salen de la UI; las activas no se tocan.
    public func purgeInvalidated() async {
        _ = try? await brain.purgeInvalidated()
        showInvalidated = false
        await load()
    }

    public static func origin(_ record: MemoryRecord) -> String {
        if record.consolidationCycle > 0 {
            let stage: String
            switch record.kind {
            case .reflection: stage = "reflexión"
            case .lesson: stage = "lección"
            default: stage = record.revisesId != nil ? "reconsolidación" : "destilado"
            }
            return "Noche #\(record.consolidationCycle) · \(stage)"
        }
        if record.source.hasPrefix("turn") || record.source.hasPrefix("chat") { return "Chat" }
        return "origen desconocido"
    }

    public static func kindLabel(_ kind: MemoryKind) -> String {
        switch kind {
        case .semantic: return "semántica"
        case .episodic: return "episódica"
        case .procedural: return "procedimental"
        case .reflection: return "reflexión"
        case .lesson: return "lección"
        }
    }

    public static func confidenceLabel(_ confidence: Double) -> String {
        "confianza \(Int((confidence * 100).rounded())) %"
    }
}

public struct MemoryDetail: Identifiable, Sendable {
    public let id: MemoryID
    public var chain: [MemoryRecord]
    public var content: String = ""
    public var origin: String = ""
    public var date: String = ""
    public var isValid = true
}

public struct MemoryBrowserView: View {
    @ObservedObject private var model: MemoryBrowserViewModel
    @State private var confirmPurge = false

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
                        if model.active.isEmpty {
                            Text("Sin memorias activas todavía. Se forman de noche con lo que vivimos.")
                                .font(Theme.Type_.secondary)
                                .foregroundStyle(Theme.Colors.textFaint)
                        }
                        ForEach(model.active) { row($0) }
                        if !model.invalidated.isEmpty {
                            invalidatedHeader
                            if model.showInvalidated {
                                // Identidad propia: la misma memoria pudo pintarse antes como activa.
                                ForEach(model.invalidated, id: \.invalidatedKey) { row($0) }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.screenInset)
                    .padding(.bottom, Theme.Space.sectionGap)
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
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.Colors.surface)
        }
        .confirmationDialog("¿Vaciar las invalidadas?", isPresented: $confirmPurge, titleVisibility: .visible) {
            Button("Vaciar", role: .destructive) { Task { await model.purgeInvalidated() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Salen de esta lista. Tus memorias activas no se tocan.")
        }
    }

    private var invalidatedHeader: some View {
        HStack {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { model.showInvalidated.toggle() }
            } label: {
                HStack(spacing: Theme.Space.unit * 1.5) {
                    Image(systemName: "chevron.right")
                        .font(Theme.Type_.label.weight(.light))
                        .rotationEffect(.degrees(model.showInvalidated ? 90 : 0))
                    Text(model.showInvalidated ? "Ocultar invalidadas" : "Mostrar invalidadas (\(model.invalidated.count))")
                }
                .font(Theme.Type_.secondary)
                .foregroundStyle(Theme.Colors.textMuted)
                .frame(minHeight: Theme.minHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("memory.toggleInvalidated")
            Spacer()
            if model.showInvalidated {
                Button("Vaciar invalidadas") { confirmPurge = true }
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.accentText)
                    .frame(minHeight: Theme.minHitTarget)
                    .accessibilityIdentifier("memory.purge")
            }
        }
        .padding(.top, Theme.Space.unit * 2)
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
                Text("\(item.origin) · \(model.dates.moment(item.createdAt, now: Date()))")
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textFaint)
                    .accessibilityIdentifier("memory.origin")
                HStack(spacing: Theme.Space.unit * 2) {
                    tag(MemoryBrowserViewModel.kindLabel(item.kind))
                    tag(MemoryBrowserViewModel.confidenceLabel(item.confidence))
                    if !item.isValid { tag("invalidada") }
                    Spacer()
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
            .opacity(item.isValid ? 1 : 0.7)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(item.isValid ? "memory.item" : "memory.item.invalidated")
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(Theme.Type_.meta)
            .foregroundStyle(Theme.Colors.textMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.Colors.tint))
    }
}

/// Detalle: la memoria, su origen y fecha, el historial de reconsolidaciones y,
/// abajo, "Invalidar" como botón real (razón opcional, confirmación ligera).
struct MemoryDetailSheet: View {
    let detail: MemoryDetail
    let onInvalidate: (MemoryID, String) -> Void
    @State private var reason: String = ""
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
        SheetHeader("Recuerdo", screen: "memoryDetail") { dismiss() }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.top, Theme.Space.sectionGap)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
                VStack(alignment: .leading, spacing: Theme.Space.unit * 1.5) {
                    Text(detail.content)
                        .font(Theme.Type_.cardTitle)
                        .foregroundStyle(Theme.Colors.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text([detail.origin, detail.date].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Theme.Type_.meta)
                        .foregroundStyle(Theme.Colors.textFaint)
                }
                if detail.chain.count > 1 {
                    VStack(alignment: .leading, spacing: Theme.Space.stack) {
                        Text("Historial de reconsolidaciones")
                            .font(Theme.Type_.label)
                            .textCase(.uppercase)
                            .kerning(0.66)
                            .foregroundStyle(Theme.Colors.textMuted)
                        ForEach(detail.chain) { record in
                            VStack(alignment: .leading, spacing: Theme.Space.unit) {
                                Text(record.content)
                                    .font(Theme.Type_.secondary)
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
                    }
                }
                if detail.isValid {
                    VStack(alignment: .leading, spacing: Theme.Space.stack) {
                        TextField("Razón (opcional)", text: $reason)
                            .font(Theme.Type_.body)
                            .foregroundStyle(Theme.Colors.text)
                            .padding(Theme.Space.cardPad)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                            .accessibilityIdentifier("memory.reason")
                        Button { confirming = true } label: {
                            Label("Invalidar recuerdo", systemImage: "xmark.circle")
                                .font(Theme.Type_.body)
                                .foregroundStyle(Theme.Colors.accentText)
                                .frame(maxWidth: .infinity, minHeight: Theme.minHitTarget)
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                                    .strokeBorder(Theme.Colors.accent, lineWidth: Theme.Stroke.hairline))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("memory.invalidate")
                    }
                }
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.top, Theme.Space.stack)
            .padding(.bottom, Theme.Space.screenInset)
        }
        .scrollDismissesKeyboard(.interactively)
        }
        .confirmationDialog("¿Invalidar este recuerdo?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Invalidar", role: .destructive) { onInvalidate(detail.id, reason) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Ella deja de usarlo; queda en el historial.")
        }
    }
}
#endif
