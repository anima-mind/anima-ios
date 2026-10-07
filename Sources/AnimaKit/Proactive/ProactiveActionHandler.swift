// ProactiveActionHandler.swift — lo que pasa al responder una notificación de
// Anima. Las acciones ("Hecho", "En 1 hora", "Sí, avancé", "Hoy no") corren SIN
// abrir la app (el shell despierta en background); el tap por defecto abre el
// deep link. La traducción desde UNNotificationResponse vive en el shell.

import Foundation

public enum ProactiveNotificationAction: Sendable, Equatable {
    case reminderDone(id: String)
    case reminderSnooze(id: String)
    case checkIn(goalId: String, answer: CheckInAnswer)
    case open(AnimaDeepLink)

    /// `actionIdentifier` + el deep link del userInfo → acción. nil si no es de Anima.
    public static func from(actionIdentifier: String, link: URL?) -> ProactiveNotificationAction? {
        guard let link, let parsed = AnimaDeepLink.parse(link) else { return nil }
        switch (actionIdentifier, parsed) {
        case (ProactiveNotificationIDs.reminderDoneAction, .reminder(let id)):
            return .reminderDone(id: id)
        case (ProactiveNotificationIDs.reminderSnoozeAction, .reminder(let id)):
            return .reminderSnooze(id: id)
        case (ProactiveNotificationIDs.checkInYesAction, .goal(let id)):
            return .checkIn(goalId: id, answer: .yes)
        case (ProactiveNotificationIDs.checkInNoAction, .goal(let id)):
            return .checkIn(goalId: id, answer: .no)
        default:
            return .open(parsed)
        }
    }
}

public struct ProactiveActionHandler: Sendable {
    public static let notificationNote = "respondido desde la notificación"
    public static let widgetNote = "respondido desde el widget"

    private let reminders: AnimaReminderStore?
    private let otherModel: OtherModel?
    private let scheduler: ProactiveScheduler?

    public init(reminders: AnimaReminderStore?, otherModel: OtherModel?, scheduler: ProactiveScheduler?) {
        self.reminders = reminders
        self.otherModel = otherModel
        self.scheduler = scheduler
    }

    /// Aplica una acción en background. `.open` no se maneja aquí (es del shell).
    /// `note`: de dónde respondió el dueño (notificación o widget).
    @discardableResult
    public func handle(_ action: ProactiveNotificationAction,
                       note: String = ProactiveActionHandler.notificationNote) async -> Bool {
        let handled: Bool
        switch action {
        case .reminderDone(let id):
            handled = (try? await reminders?.complete(id: id)) != nil
        case .reminderSnooze(let id):
            handled = (try? await reminders?.snooze(id: id, minutes: ProactiveNotificationIDs.snoozeMinutes)) != nil
        case .checkIn(let goalId, let answer):
            handled = await otherModel?.recordCheckIn(goalId: goalId, answer: answer,
                                                       note: note) != nil
        case .open:
            return false
        }
        if handled { await scheduler?.sync() }
        return handled
    }

    /// Un botón de widget de la cola: con la hora del tap, idempotente al
    /// reaplicarse ("Hecho" sobre uno cerrado = obsoleta; check-in una vez por
    /// día) y `.failed` si la base falló (el tap queda en la cola).
    @discardableResult
    public func handle(_ action: WidgetAction) async -> WidgetActionOutcome {
        let outcome: WidgetActionOutcome
        do {
            switch action.kind {
            case .reminderDone(let id):
                guard let reminders else { return .failed }
                outcome = try await reminders.completeFromWidget(id: id, at: action.createdAt) ? .applied : .obsolete
            case .checkInProgress(let goalId):
                guard let otherModel else { return .failed }
                let recorded = try await otherModel.applyCheckIn(goalId: goalId, answer: .yes, note: Self.widgetNote,
                                                                 answeredAt: action.createdAt, oncePerDay: true)
                outcome = recorded == nil ? .obsolete : .applied
            }
        } catch {
            return .failed
        }
        if outcome == .applied { await scheduler?.sync() }
        return outcome
    }
}

extension WidgetAction {
    /// La misma acción que dispara el botón de la notificación equivalente.
    public var proactiveAction: ProactiveNotificationAction {
        switch kind {
        case .reminderDone(let id): return .reminderDone(id: id)
        case .checkInProgress(let goalId): return .checkIn(goalId: goalId, answer: .yes)
        }
    }
}
