// GoalsView.swift — el deseo del dueño visible (§5.8). Lista los Goals con su
// fuente (stated/inferred/structural), estado y evidencia; permite confirmar o
// abandonar manualmente. Los inferred pendientes también viven en el inbox de
// Aprobaciones; aquí se ven todos, incluidos achieved/abandoned, para inspección.
// Cada meta activa lleva su check-in (cadencia + hora) — el mismo que se fija
// por conversación con la tool `goals` — con racha y último check-in.

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class GoalsViewModel: ObservableObject {
    public struct Progress: Equatable, Sendable {
        public var streak: Int
        public var last: GoalCheckIn?
    }

    @Published public private(set) var goals: [Goal] = []
    @Published public private(set) var progress: [String: Progress] = [:]
    private let otherModel: OtherModel
    /// Re-sincroniza las notificaciones locales tras cambiar cadencia/estado.
    public var onCheckInChanged: (@Sendable () async -> Void)?

    public init(otherModel: OtherModel) {
        self.otherModel = otherModel
    }

    public func refresh() async {
        let all = await otherModel.allGoals()
        var next: [String: Progress] = [:]
        for goal in all where goal.status == .active {
            next[goal.id] = Progress(streak: await otherModel.streak(goalId: goal.id),
                                     last: await otherModel.lastCheckIn(goalId: goal.id))
        }
        goals = all
        progress = next
    }

    public func confirm(_ goal: Goal) async {
        await otherModel.confirm(id: goal.id)
        await changed()
    }

    public func abandon(_ goal: Goal) async {
        await otherModel.abandon(id: goal.id)
        await changed()
    }

    public func markAchieved(_ goal: Goal) async {
        await otherModel.markAchieved(id: goal.id)
        await changed()
    }

    public func setCadence(_ goal: Goal, _ cadence: ProactiveCadence) async {
        var checkIn = goal.checkIn
        checkIn.cadence = cadence
        if cadence == .weekly, checkIn.weekday == nil {
            checkIn.weekday = Calendar.current.component(.weekday, from: Date())
        }
        await apply(goal, checkIn)
    }

    public func setTime(_ goal: Goal, _ date: Date) async {
        var checkIn = goal.checkIn
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        checkIn.hour = parts.hour ?? CheckInCadence.defaultHour
        checkIn.minute = parts.minute ?? 0
        await apply(goal, checkIn)
    }

    public func setWeekday(_ goal: Goal, _ weekday: Int) async {
        var checkIn = goal.checkIn
        checkIn.weekday = weekday
        await apply(goal, checkIn)
    }

    private func apply(_ goal: Goal, _ checkIn: CheckInCadence) async {
        await otherModel.setCheckIn(id: goal.id, checkIn)
        await changed()
    }

    private func changed() async {
        await refresh()
        await onCheckInChanged?()
    }

    /// "Check-in cada día a las 20:00 · racha 4 días · último: sí, hoy".
    public static func checkInStatus(_ goal: Goal, _ progress: Progress?) -> String {
        var parts = [goal.checkIn.isActive ? "Check-in \(goal.checkIn.phrase)" : "Sin check-in"]
        if let progress {
            if progress.streak > 0 { parts.append("racha \(progress.streak) \(progress.streak == 1 ? "día" : "días")") }
            if let last = progress.last, let answer = last.answer, let at = last.answeredAt {
                parts.append("último: \(answerLabel(answer)), \(relativeDay(at))")
            }
        }
        return parts.joined(separator: " · ")
    }

    static func answerLabel(_ answer: CheckInAnswer) -> String {
        switch answer {
        case .yes: return "sí"
        case .partial: return "a medias"
        case .no: return "no"
        case .skipped: return "sin responder"
        }
    }

    static func relativeDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 0: return "hoy"
        case 1: return "ayer"
        default: return "hace \(days) días"
        }
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
            if goal.status == .active {
                checkInRow(goal)
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
        .contextMenu {
            if goal.status == .active {
                Button("Marcar lograda") { Task { await model.markAchieved(goal) } }
                Button("Abandonar", role: .destructive) { Task { await model.abandon(goal) } }
            }
        }
    }

    private static let cadenceOptions: [(ProactiveCadence, String)] = [
        (.none, "Ninguno"), (.daily, "Diario"), (.weekdays, "Entre semana"), (.weekly, "Semanal"),
    ]

    /// Check-in de la meta: cadencia + hora (+ día si es semanal), racha y último.
    private func checkInRow(_ goal: Goal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Theme.Colors.border)
            HStack(spacing: Theme.Space.stack) {
                Text("Check-in")
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.textMuted)
                Spacer()
                Picker("Check-in", selection: Binding(
                    get: { goal.checkIn.cadence },
                    set: { cadence in Task { await model.setCadence(goal, cadence) } })) {
                    ForEach(Self.cadenceOptions, id: \.0) { option in
                        Text(option.1).tag(option.0)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("goal.checkin.cadence.\(goal.id)")
            }
            if goal.checkIn.isActive {
                HStack(spacing: Theme.Space.stack) {
                    if goal.checkIn.cadence == .weekly {
                        Picker("Día", selection: Binding(
                            get: { goal.checkIn.weekday ?? 2 },
                            set: { day in Task { await model.setWeekday(goal, day) } })) {
                            ForEach(1...7, id: \.self) { day in
                                Text(CheckInCadence.weekdayName(day).capitalized).tag(day)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("goal.checkin.weekday.\(goal.id)")
                    }
                    Spacer()
                    DatePicker("Hora", selection: Binding(
                        get: { Self.time(goal.checkIn) },
                        set: { date in Task { await model.setTime(goal, date) } }),
                               displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .accessibilityIdentifier("goal.checkin.time.\(goal.id)")
                }
            }
            Text(GoalsViewModel.checkInStatus(goal, model.progress[goal.id]))
                .font(Theme.Type_.meta)
                .foregroundStyle(Theme.Colors.textFaint)
                .accessibilityIdentifier("goal.checkin.status.\(goal.id)")
        }
        .padding(.top, 4)
    }

    private static func time(_ checkIn: CheckInCadence) -> Date {
        Calendar.current.date(bySettingHour: checkIn.hour, minute: checkIn.minute, second: 0, of: Date()) ?? Date()
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
