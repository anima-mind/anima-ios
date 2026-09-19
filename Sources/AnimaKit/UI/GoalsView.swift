// GoalsView.swift — el deseo del dueño visible (§5.8). Lista los Goals con su
// fuente (stated/inferred/structural), estado y evidencia; permite confirmar o
// abandonar manualmente. Los inferred pendientes también viven en el inbox de
// Aprobaciones; aquí se ven todos, incluidos achieved/abandoned, para inspección.

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class GoalsViewModel: ObservableObject {
    @Published public private(set) var goals: [Goal] = []
    private let otherModel: OtherModel

    public init(otherModel: OtherModel) {
        self.otherModel = otherModel
    }

    public func refresh() async {
        goals = await otherModel.allGoals()
    }

    public func confirm(_ goal: Goal) async {
        await otherModel.confirm(id: goal.id)
        await refresh()
    }

    public func abandon(_ goal: Goal) async {
        await otherModel.abandon(id: goal.id)
        await refresh()
    }
}

public struct GoalsView: View {
    @ObservedObject private var model: GoalsViewModel

    public init(model: GoalsViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            Group {
                if model.goals.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: Theme.Space.stack) {
                            ForEach(model.goals) { goal in card(goal) }
                        }
                        .padding(Theme.Space.screenInset)
                    }
                }
            }
            .background(Theme.Colors.bg)
            .navigationTitle("Metas")
        }
        .task { await model.refresh() }
        .tint(Theme.Colors.accent)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.stack) {
            Text("Sin metas todavía")
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.textMuted)
            Text("Anima aprende tus metas de lo que le cuentas; aquí las verás con su fuente y estado.")
                .font(Theme.Type_.secondary)
                .foregroundStyle(Theme.Colors.textFaint)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Space.screenInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.bg)
    }

    private func card(_ goal: Goal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(goal.source.rawValue.uppercased())
                    .font(Theme.Type_.label)
                    .kerning(0.66)
                    .foregroundStyle(Theme.Colors.textMuted)
                Spacer()
                Text(statusLabel(goal.status))
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textFaint)
            }
            Text(goal.statement)
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.text)
            Text(goal.desiredState.label)
                .font(Theme.Type_.secondary)
                .foregroundStyle(Theme.Colors.textMuted)
            if !goal.evidence.isEmpty {
                Text(goal.evidence)
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.textFaint)
            }
            if goal.status == .pendingConfirmation {
                HStack(spacing: Theme.Space.stack) {
                    Button("Abandonar") { Task { await model.abandon(goal) } }
                        .foregroundStyle(Theme.Colors.textMuted)
                    Spacer()
                    Button("Confirmar") { Task { await model.confirm(goal) } }
                        .foregroundStyle(Theme.Colors.accent)
                }
                .font(Theme.Type_.body)
                .padding(.top, 4)
            }
        }
        .padding(Theme.Space.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(goal.status == .pendingConfirmation ? Theme.Colors.accent : Theme.Colors.border,
                              lineWidth: Theme.Stroke.hairline))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func statusLabel(_ status: GoalStatus) -> String {
        switch status {
        case .active: return "activa"
        case .achieved: return "lograda"
        case .abandoned: return "abandonada"
        case .pendingConfirmation: return "por confirmar"
        }
    }
}
#endif
