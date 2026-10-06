// GoalsView.swift — el deseo del dueño visible (§5.8). Lista los Goals con su
// fuente (stated/inferred/structural), estado y evidencia; permite confirmar o
// abandonar manualmente. Los inferred pendientes también viven en "Por aprobar"
// (Ajustes → Mente); aquí se ven todos, incluidos achieved/abandoned, para inspección.
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
    /// Meta a la que saltar (check-in tocado en la tab Recordatorios).
    @Published public var focusedGoalId: String?

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

    public func focus(goalId: String) {
        focusedGoalId = goalId
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

    /// "Seguimiento cada día a las 8:00 p. m. · racha 4 días · último: sí, hoy".
    public static func checkInStatus(_ goal: Goal, _ progress: Progress?, dates: AnimaDateText = AnimaDateText()) -> String {
        var parts = [goal.checkIn.isActive ? "Seguimiento \(followUpPhrase(goal.checkIn, dates: dates))" : "Sin seguimiento"]
        if let progress {
            if progress.streak > 0 { parts.append("racha \(progress.streak) \(progress.streak == 1 ? "día" : "días")") }
            if let last = progress.last, let answer = last.answer, let at = last.answeredAt {
                parts.append("último: \(answerLabel(answer)), \(relativeDay(at))")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// "cada día a las 8:00 p. m.", "entre semana a las 7:30 a. m.", "cada domingo a las 8:00 p. m.".
    public static func followUpPhrase(_ checkIn: CheckInCadence, dates: AnimaDateText = AnimaDateText()) -> String {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 1
        comps.hour = checkIn.hour; comps.minute = checkIn.minute
        let time = dates.calendar.date(from: comps).map(dates.time) ?? String(format: "%02d:%02d", checkIn.hour, checkIn.minute)
        switch checkIn.cadence {
        case .none: return "sin seguimiento"
        case .daily: return "cada día a las \(time)"
        case .weekdays: return "entre semana a las \(time)"
        case .weekly: return "cada \(CheckInCadence.weekdayName(checkIn.weekday ?? 2)) a las \(time)"
        }
    }

    /// STATED → "Declarada" (y compañía): la fuente en español.
    public static func sourceLabel(_ source: GoalSource) -> String {
        switch source {
        case .stated: return "Declarada"
        case .inferred: return "Inferida"
        case .structural: return "Estructural"
        }
    }

    /// Activas y por confirmar arriba; logradas y abandonadas en "Historial".
    public var currentGoals: [Goal] { goals.filter { $0.status == .active || $0.status == .pendingConfirmation } }
    public var pastGoals: [Goal] { goals.filter { $0.status == .achieved || $0.status == .abandoned } }

    /// "Eliminar" = abandonar: deja de motivar y se cancelan sus avisos.
    public func delete(_ goal: Goal) async {
        await abandon(goal)
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
    @State private var showHistory = false
    @State private var pendingDelete: Goal?

    public init(model: GoalsViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            Group {
                if model.goals.isEmpty {
                    emptyState
                } else {
                    ScrollViewReader { proxy in
                        list
                            .onAppear { scroll(proxy, to: model.focusedGoalId) }
                            .onChange(of: model.focusedGoalId) { _, id in scroll(proxy, to: id) }
                    }
                }
            }
            .background(Theme.Colors.bg)
            .navigationTitle("Metas")
        }
        .task { await model.refresh() }
        .tint(Theme.Colors.accent)
        .confirmationDialog("¿Eliminar esta meta?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { goal in
            Button("Eliminar", role: .destructive) { Task { await model.delete(goal) } }
            Button("Cancelar", role: .cancel) {}
        } message: { _ in
            Text("Deja de motivarte y se cancelan sus avisos. Queda en el historial.")
        }
    }

    private var list: some View {
        List {
            Section {
                if model.currentGoals.isEmpty {
                    Text("Sin metas activas. Cuéntale a Anima qué quieres lograr.")
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.textFaint)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(model.currentGoals) { goal in
                    card(goal)
                        .id(goal.id)
                        .listRowInsets(EdgeInsets(top: 6, leading: Theme.Space.screenInset,
                                                  bottom: 6, trailing: Theme.Space.screenInset))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { pendingDelete = goal } label: {
                                Label("Eliminar", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if goal.status == .active {
                                Button { Task { await model.markAchieved(goal) } } label: {
                                    Label("Marcar lograda", systemImage: "checkmark")
                                }
                                .tint(Theme.Colors.accent)
                            }
                        }
                }
            }
            if !model.pastGoals.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showHistory) {
                        ForEach(model.pastGoals) { goal in
                            pastRow(goal)
                        }
                    } label: {
                        Text("Historial (\(model.pastGoals.count))")
                            .font(Theme.Type_.secondary)
                            .foregroundStyle(Theme.Colors.textMuted)
                    }
                    .accessibilityIdentifier("goals.history")
                    .listRowBackground(Theme.Colors.surface)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: String?) {
        guard let id else { return }
        withAnimation { proxy.scrollTo(id, anchor: .top) }
        model.focusedGoalId = nil
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

    private func pastRow(_ goal: Goal) -> some View {
        HStack {
            Text(goal.statement)
                .font(Theme.Type_.secondary)
                .foregroundStyle(Theme.Colors.textMuted)
            Spacer()
            Text(statusLabel(goal.status))
                .font(Theme.Type_.meta)
                .foregroundStyle(Theme.Colors.textFaint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("goals.history.item")
    }

    private func card(_ goal: Goal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(GoalsViewModel.sourceLabel(goal.source))
                    .font(Theme.Type_.label)
                    .textCase(.uppercase)
                    .kerning(0.66)
                    .foregroundStyle(Theme.Colors.textMuted)
                    .accessibilityIdentifier("goal.source")
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
                .buttonStyle(.plain)
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
                Button { Task { await model.markAchieved(goal) } } label: {
                    Label("Marcar lograda", systemImage: "checkmark")
                }
            }
            Button(role: .destructive) { pendingDelete = goal } label: {
                Label("Eliminar", systemImage: "trash")
            }
        }
    }

    private static let cadenceOptions: [(ProactiveCadence, String)] = [
        (.none, "Ninguno"), (.daily, "Diario"), (.weekdays, "Entre semana"), (.weekly, "Semanal"),
    ]

    /// Seguimiento de la meta en UNA línea: cadencia (+ día) + hora; abajo el resumen.
    private func checkInRow(_ goal: Goal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Theme.Colors.border)
            HStack(spacing: 8) {
                Text("Seguimiento")
                    .font(Theme.Type_.secondary)
                    .foregroundStyle(Theme.Colors.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Picker("Seguimiento", selection: Binding(
                    get: { goal.checkIn.cadence },
                    set: { cadence in Task { await model.setCadence(goal, cadence) } })) {
                    ForEach(Self.cadenceOptions, id: \.0) { option in
                        Text(option.1).tag(option.0)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("goal.checkin.cadence.\(goal.id)")
                if goal.checkIn.cadence == .weekly {
                    Picker("Día", selection: Binding(
                        get: { goal.checkIn.weekday ?? 2 },
                        set: { day in Task { await model.setWeekday(goal, day) } })) {
                        ForEach(1...7, id: \.self) { day in
                            Text(CheckInCadence.weekdayName(day).capitalized).tag(day)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("goal.checkin.weekday.\(goal.id)")
                }
                if goal.checkIn.isActive {
                    DatePicker("Hora", selection: Binding(
                        get: { Self.time(goal.checkIn) },
                        set: { date in Task { await model.setTime(goal, date) } }),
                               displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .fixedSize()
                        .environment(\.locale, Locale(identifier: "es_CO"))
                        .accessibilityIdentifier("goal.checkin.time.\(goal.id)")
                }
            }
            Text(GoalsViewModel.checkInStatus(goal, model.progress[goal.id]))
                .font(Theme.Type_.secondary)
                .foregroundStyle(Theme.Colors.textFaint)
                .fixedSize(horizontal: false, vertical: true)
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
