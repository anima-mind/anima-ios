// RemindersSection.swift — lo que Anima tiene programado para decirte, visible:
// sus recordatorios (qué, cuándo, si se repite) con Hecho / Cancelar, y los
// check-ins activos de tus metas. Vive arriba de la tab Metas y es el destino
// de "N programados" en Ajustes → Notificaciones (la MISMA instancia).

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
        Item(id: "checkin-\(goal.id)", kind: .checkIn(goalId: goal.id), title: "Check-in · \(goal.statement)",
             spoken: nil, schedule: goal.checkIn.phrase)
    }

    static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

/// La sección: encabezado, filas y estado vacío amable. `onOpenGoal` lleva a
/// la meta del check-in (en la tab Metas, scroll a su card).
public struct RemindersSection: View {
    @ObservedObject var model: RemindersViewModel
    var onOpenGoal: ((String) -> Void)?

    public init(model: RemindersViewModel, onOpenGoal: ((String) -> Void)? = nil) {
        self.model = model
        self.onOpenGoal = onOpenGoal
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recordatorios")
                .font(Theme.Type_.label)
                .textCase(.uppercase)
                .kerning(0.66)
                .foregroundStyle(Theme.Colors.textMuted)
                .accessibilityIdentifier("reminders.header")
            if model.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(Array((model.reminders + model.checkIns).enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Rectangle().fill(Theme.Colors.border).frame(height: Theme.Stroke.hairline)
                                .padding(.leading, 46)
                        }
                        row(item)
                    }
                }
                .background(Theme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reminders.section")
    }

    private var emptyState: some View {
        Text("Nada programado. Dile \"recuérdame…\" en el chat y aquí verás qué te va a decir y cuándo.")
            .font(Theme.Type_.secondary)
            .foregroundStyle(Theme.Colors.textFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Theme.Space.cardPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
            .accessibilityIdentifier("reminders.empty")
    }

    @ViewBuilder
    private func row(_ item: RemindersViewModel.Item) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.stack) {
            Image(systemName: item.kind == .reminder ? "bell" : "target")
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 20)
                .padding(.top, 2)
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
                    .accessibilityIdentifier("reminders.schedule")
            }
            Spacer(minLength: 0)
            actions(item)
        }
        .padding(.horizontal, Theme.Space.cardPad)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu { menuItems(item) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reminders.item")
    }

    @ViewBuilder
    private func actions(_ item: RemindersViewModel.Item) -> some View {
        switch item.kind {
        case .reminder:
            Menu {
                menuItems(item)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(Theme.Colors.textMuted)
                    .frame(width: Theme.minHitTarget, height: Theme.minHitTarget)
            }
            .accessibilityLabel("Acciones del recordatorio")
            .accessibilityIdentifier("reminders.actions")
        case .checkIn(let goalId):
            if let onOpenGoal {
                Button { onOpenGoal(goalId) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(Theme.Colors.textFaint)
                        .frame(width: Theme.minHitTarget, height: Theme.minHitTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ver la meta")
                .accessibilityIdentifier("reminders.openGoal")
            }
        }
    }

    @ViewBuilder
    private func menuItems(_ item: RemindersViewModel.Item) -> some View {
        if item.kind == .reminder {
            Button { Task { await model.complete(item) } } label: { Label("Hecho", systemImage: "checkmark") }
            Button(role: .destructive) { Task { await model.cancel(item) } } label: {
                Label("Cancelar", systemImage: "xmark")
            }
        }
    }
}

/// Pantalla propia (Ajustes → Notificaciones → "N programados").
public struct RemindersScreen: View {
    @ObservedObject var model: RemindersViewModel

    public init(model: RemindersViewModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            Theme.Colors.bg.ignoresSafeArea()
            ScrollView {
                RemindersSection(model: model)
                    .padding(Theme.Space.screenInset)
            }
        }
        .navigationTitle("Recordatorios")
        .navigationBarTitleDisplayModeInline()
        .task { await model.refresh() }
    }
}
#endif
