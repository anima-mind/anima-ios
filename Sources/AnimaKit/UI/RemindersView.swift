// RemindersView.swift — la tab Recordatorios: lo que Anima tiene programado
// para decirte (qué, qué te dirá, cuándo, si se repite) con Hecho / Cancelar por
// swipe o context menu, y los check-ins activos de tus metas (→ la meta). Es el
// destino de "N programados" en Ajustes → Notificaciones.

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class RemindersViewModel: ObservableObject {
    public struct Item: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case reminder
            case checkIn(goalId: String)
        }

        public var id: String
        public var kind: Kind
        public var title: String
        /// Lo que ella te dirá (recordatorios con `message`).
        public var spoken: String?
        /// "hoy 8:30 p. m. · cada día" | "cada día a las 20:00".
        public var schedule: String
    }

    @Published public private(set) var reminders: [Item] = []
    @Published public private(set) var checkIns: [Item] = []
    private let store: AnimaReminderStore
    private let otherModel: OtherModel?
    /// Re-sincroniza las notificaciones locales tras Hecho / Cancelar.
    public var onChange: (@Sendable () async -> Void)?
    /// Check-in → su meta (el shell salta a la tab Metas).
    public var onOpenGoal: ((String) -> Void)?
    public var now: @Sendable () -> Date = { Date() }
    public var dates = AnimaDateText()

    public init(store: AnimaReminderStore, otherModel: OtherModel?) {
        self.store = store
        self.otherModel = otherModel
    }

    public var isEmpty: Bool { reminders.isEmpty && checkIns.isEmpty }

    public func refresh() async {
        let reference = now()
        reminders = await store.list(.upcoming).map { Self.item($0, now: reference, dates: dates) }
        var next: [Item] = []
        for goal in await otherModel?.desire() ?? [] where goal.checkIn.isActive && goal.checkIn.isValid {
            next.append(Self.item(checkIn: goal))
        }
        checkIns = next
    }

    public func complete(_ item: Item) async {
        guard item.kind == .reminder else { return }
        _ = try? await store.complete(id: item.id)
        await changed()
    }

    public func cancel(_ item: Item) async {
        guard item.kind == .reminder else { return }
        _ = try? await store.cancel(id: item.id)
        await changed()
    }

    private func changed() async {
        await onChange?()
        await refresh()
    }

    static func item(_ reminder: AnimaReminder, now: Date, dates: AnimaDateText) -> Item {
        let when = dates.moment(reminder.fireAt, now: now)
        let schedule = reminder.repeatCadence.phrase.map { "\(when) · \($0)" } ?? when
        return Item(id: reminder.id, kind: .reminder, title: capitalized(reminder.text), spoken: reminder.message,
                    schedule: schedule)
    }

    static func item(checkIn goal: Goal) -> Item {
        Item(id: "checkin-\(goal.id)", kind: .checkIn(goalId: goal.id), title: "Seguimiento · \(goal.statement)",
             spoken: nil, schedule: GoalsViewModel.followUpPhrase(goal.checkIn))
    }

    static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

extension View {
    /// insetGrouped en iOS (no existe en macOS: el package compila en ambos).
    @ViewBuilder
    func insetGroupedListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self
        #endif
    }
}

public struct RemindersView: View {
    @ObservedObject private var model: RemindersViewModel

    public static let emptyHint = "Dime: «recuérdame mañana a las 9…» y aquí verás qué te voy a decir y cuándo."

    public init(model: RemindersViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            Group {
                if model.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Theme.Colors.bg)
            .navigationTitle("Recordatorios")
        }
        .task { await model.refresh() }
        .tint(Theme.Colors.accent)
    }

    private var list: some View {
        List {
            if !model.reminders.isEmpty {
                Section {
                    ForEach(model.reminders) { item in
                        reminderRow(item)
                    }
                } header: {
                    sectionHeader("Programados")
                }
            }
            if !model.checkIns.isEmpty {
                Section {
                    ForEach(model.checkIns) { item in
                        checkInRow(item)
                    }
                } header: {
                    sectionHeader("Seguimientos")
                }
            }
        }
        .insetGroupedListStyle()
        .scrollContentBackground(.hidden)
        .refreshable { await model.refresh() }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.stack) {
            Image(systemName: "bell")
                .font(Theme.Type_.hero.weight(.light))
                .foregroundStyle(Theme.Colors.accent)
            Text("Nada programado")
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.textMuted)
            Text(Self.emptyHint)
                .font(Theme.Type_.secondary)
                .foregroundStyle(Theme.Colors.textFaint)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Space.screenInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reminders.empty")
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(Theme.Type_.label)
            .textCase(.uppercase)
            .kerning(0.66)
            .foregroundStyle(Theme.Colors.textMuted)
    }

    private func reminderRow(_ item: RemindersViewModel.Item) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.stack) {
            Image(systemName: "bell")
                .font(Theme.Type_.body.weight(.light))
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 20)
                .padding(.top, Theme.Space.unit / 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(Theme.Type_.body)
                    .foregroundStyle(Theme.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let spoken = item.spoken {
                    Text("«\(spoken)»")
                        .font(Theme.Type_.secondary)
                        .foregroundStyle(Theme.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(item.schedule)
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.accentText)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.unit)
        .listRowBackground(Theme.Colors.surface)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { Task { await model.cancel(item) } } label: {
                Label("Cancelar", systemImage: "xmark")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { Task { await model.complete(item) } } label: {
                Label("Hecho", systemImage: "checkmark")
            }
            .tint(Theme.Colors.accent)
        }
        .contextMenu {
            Button { Task { await model.complete(item) } } label: { Label("Hecho", systemImage: "checkmark") }
            Button(role: .destructive) { Task { await model.cancel(item) } } label: {
                Label("Cancelar", systemImage: "xmark")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reminders.item")
    }

    private func checkInRow(_ item: RemindersViewModel.Item) -> some View {
        Button {
            if case .checkIn(let goalId) = item.kind { model.onOpenGoal?(goalId) }
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.stack) {
                Image(systemName: "target")
                    .font(Theme.Type_.body.weight(.light))
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(width: 20)
                    .padding(.top, Theme.Space.unit / 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(Theme.Type_.body)
                        .foregroundStyle(Theme.Colors.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.schedule)
                        .font(Theme.Type_.meta)
                        .foregroundStyle(Theme.Colors.accentText)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Theme.Type_.meta.weight(.light))
                    .foregroundStyle(Theme.Colors.textFaint)
                    .padding(.top, Theme.Space.unit)
            }
            .padding(.vertical, Theme.Space.unit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.Colors.surface)
        .accessibilityIdentifier("reminders.checkin")
    }
}
#endif
