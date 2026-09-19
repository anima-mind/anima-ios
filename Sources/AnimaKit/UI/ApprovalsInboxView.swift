// ApprovalsInboxView.swift — la bandeja de PendingOtherApproval (§5.5). Lista los
// cambios identitarios que la plasticidad no dejó aplicar directo, con su diff
// (antes → después, por qué). El Otro (el dueño) aprueba o rechaza cambios
// concretos, no "confía en mí". Sin respuesta en 7 días → Rejected (fail-closed,
// lo resuelve SelfModel.expireStale al abrir la app o en el ciclo).

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class ApprovalsInboxViewModel: ObservableObject {
    @Published public private(set) var pending: [PendingApproval] = []
    // Fase 4 (§5.8): el confirmation gate de Goals inferred usa el MISMO inbox —
    // un tipo de item nuevo, no una cola nueva.
    @Published public private(set) var pendingGoals: [Goal] = []
    private let selfModel: SelfModel
    private let otherModel: OtherModel?

    public init(selfModel: SelfModel, otherModel: OtherModel? = nil) {
        self.selfModel = selfModel
        self.otherModel = otherModel
    }

    public var badgeCount: Int { pending.count + pendingGoals.count }
    public var isEmpty: Bool { pending.isEmpty && pendingGoals.isEmpty }

    public func refresh() async {
        _ = await selfModel.expireStale()
        pending = await selfModel.pendingApprovals()
        pendingGoals = await otherModel?.pendingConfirmations() ?? []
    }

    public func approve(_ approval: PendingApproval) async {
        _ = await selfModel.approve(id: approval.id)
        await refresh()
    }

    public func reject(_ approval: PendingApproval) async {
        await selfModel.reject(id: approval.id)
        await refresh()
    }

    /// El dueño confirma una meta inferida → active (recién ahí puede motivar).
    public func confirmGoal(_ goal: Goal) async {
        await otherModel?.confirm(id: goal.id)
        await refresh()
    }

    /// El dueño la rechaza → abandoned (deja de existir para el deseo).
    public func abandonGoal(_ goal: Goal) async {
        await otherModel?.abandon(id: goal.id)
        await refresh()
    }
}

public struct ApprovalsInboxView: View {
    @ObservedObject private var model: ApprovalsInboxViewModel

    public init(model: ApprovalsInboxViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            Group {
                if model.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: Theme.Space.stack) {
                            ForEach(model.pendingGoals) { goal in
                                goalCard(goal)
                            }
                            ForEach(model.pending) { approval in
                                card(approval)
                            }
                        }
                        .padding(Theme.Space.screenInset)
                    }
                }
            }
            .background(Theme.Colors.bg)
            .navigationTitle("Aprobaciones")
        }
        .task { await model.refresh() }
        .tint(Theme.Colors.accent)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.stack) {
            Text("Sin cambios pendientes")
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.textMuted)
            Text("Aquí llegan los cambios de identidad que Anima propone y que requieren tu aprobación.")
                .font(Theme.Type_.secondary)
                .foregroundStyle(Theme.Colors.textFaint)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Space.screenInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.bg)
    }

    private func card(_ approval: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            Text(approval.field.rawValue.uppercased())
                .font(Theme.Type_.label)
                .kerning(0.66)
                .foregroundStyle(Theme.Colors.textMuted)

            diffRow(label: "Antes", value: approval.before.isEmpty ? "(vacío)" : approval.before,
                    color: Theme.Colors.textFaint)
            diffRow(label: "Después", value: approval.after, color: Theme.Colors.text)

            if !approval.rationale.isEmpty {
                Text("Por qué: \(approval.rationale)")
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.textMuted)
            }

            HStack(spacing: Theme.Space.stack) {
                Button("Rechazar") { Task { await model.reject(approval) } }
                    .foregroundStyle(Theme.Colors.textMuted)
                Spacer()
                Button("Aprobar") { Task { await model.approve(approval) } }
                    .foregroundStyle(Theme.Colors.accent)
            }
            .font(Theme.Type_.body)
        }
        .padding(Theme.Space.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func goalCard(_ goal: Goal) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            Text("META INFERIDA — ¿LA CONFIRMAS?")
                .font(Theme.Type_.label)
                .kerning(0.66)
                .foregroundStyle(Theme.Colors.textMuted)

            Text(goal.statement)
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.text)

            Text(goal.desiredState.label)
                .font(Theme.Type_.secondary)
                .foregroundStyle(Theme.Colors.textMuted)

            if !goal.evidence.isEmpty {
                Text("Por qué: \(goal.evidence)")
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.textFaint)
            }

            HStack(spacing: Theme.Space.stack) {
                Button("Descartar") { Task { await model.abandonGoal(goal) } }
                    .foregroundStyle(Theme.Colors.textMuted)
                Spacer()
                Button("Confirmar") { Task { await model.confirmGoal(goal) } }
                    .foregroundStyle(Theme.Colors.accent)
            }
            .font(Theme.Type_.body)
        }
        .padding(Theme.Space.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.Colors.accent, lineWidth: Theme.Stroke.hairline))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func diffRow(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.Type_.meta)
                .foregroundStyle(Theme.Colors.textFaint)
            Text(value)
                .font(Theme.Type_.body)
                .foregroundStyle(color)
        }
    }
}
#endif
