// SkillsSettingsSection.swift — sección Skills de Ajustes (§5.7): los skills del
// dir sandbox (Documents/skills) con su estado learned → practiced y un toggle
// por skill. Import por Files/paste: "pronto" (Documents aún no se expone a
// Files: haría visible también anima.sqlite).

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class SkillsViewModel: ObservableObject {
    @Published public private(set) var rows: [SkillOverview] = []
    private let engine: SkillEngine

    public init(engine: SkillEngine) {
        self.engine = engine
    }

    /// Relee el dir (hot-reload por mtime en el SkillStore) y el estado de práctica.
    public func load() {
        Task { rows = await engine.overview() }
    }

    public func setEnabled(_ name: String, _ enabled: Bool) {
        Task {
            await engine.setDisabled(name, !enabled)
            rows = await engine.overview()
        }
    }

    public static func status(_ row: SkillOverview) -> String {
        let state = row.practiced ? "practicada" : "aprendida"
        let successes = row.totalSuccess == 1 ? "1 éxito" : "\(row.totalSuccess) éxitos"
        return "\(state) · \(successes)"
    }
}

struct SkillsSettingsSection: View {
    @ObservedObject var model: SkillsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            Text("Skills")
                .font(Theme.Type_.label)
                .textCase(.uppercase)
                .kerning(0.66)
                .foregroundStyle(Theme.Colors.textMuted)
            if model.rows.isEmpty {
                Text("Sin skills todavía.")
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textFaint)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Rectangle().fill(Theme.Colors.border).frame(height: Theme.Stroke.hairline)
                        }
                        skillRow(row)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
            }
            Text("Conocimiento que Anima aplica cuando un pedido encaja; con 3 éxitos seguidos pasa a practicada. Importar desde Archivos o pegar una skill: pronto.")
                .font(Theme.Type_.meta)
                .foregroundStyle(Theme.Colors.textFaint)
        }
        .onAppear { model.load() }
    }

    private func skillRow(_ row: SkillOverview) -> some View {
        Toggle(isOn: Binding(get: { !row.disabled }, set: { model.setEnabled(row.name, $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(Theme.Type_.body)
                    .foregroundStyle(row.disabled ? Theme.Colors.textFaint : Theme.Colors.text)
                Text(SkillsViewModel.status(row))
                    .font(Theme.Type_.meta)
                    .foregroundStyle(row.practiced ? Theme.Colors.accentText : Theme.Colors.textFaint)
            }
        }
        .tint(Theme.Colors.accent)
        .frame(minHeight: 48)
        .padding(.horizontal, Theme.Space.cardPad)
        .padding(.vertical, 4)
    }
}
#endif
