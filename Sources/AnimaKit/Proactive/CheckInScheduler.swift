// CheckInScheduler.swift — el check-in por meta como notificaciones locales
// REPETITIVAS (UNCalendarNotificationTrigger repeats:true): una vez programadas,
// iOS las entrega sin que la app corra. daily = 1 request; weekdays = 5 (lun–vie);
// weekly = 1 con weekday. Solo para metas que motivan con cadencia ≠ none.

import Foundation

public enum CheckInScheduler {
    /// id `anima-checkin-<goalId>` (weekdays: `-<weekday>` por día).
    public static func requests(for goal: Goal, title: String) -> [LocalNotificationRequest] {
        guard goal.motivates, goal.checkIn.isActive, goal.checkIn.isValid else { return [] }
        let base = ProactiveNotificationIDs.checkInPrefix + goal.id
        func request(id: String, weekday: Int?) -> LocalNotificationRequest {
            var components = DateComponents()
            components.hour = goal.checkIn.hour
            components.minute = goal.checkIn.minute
            components.weekday = weekday
            return LocalNotificationRequest(
                id: id, title: title, body: body(for: goal),
                trigger: .calendar(components, repeats: true),
                categoryId: ProactiveNotificationIDs.checkInCategory,
                deepLink: AnimaDeepLink.goal(id: goal.id).url)
        }
        switch goal.checkIn.cadence {
        case .none: return []
        case .daily: return [request(id: base, weekday: nil)]
        case .weekly: return [request(id: base, weekday: goal.checkIn.weekday)]
        case .weekdays: return (2...6).map { (day: Int) in request(id: "\(base)-\(day)", weekday: day) }
        }
    }

    public static func body(for goal: Goal) -> String {
        "¿Cómo vas con \(goal.statement)?"
    }

    /// Lo que Anima dice en el chat al abrir el check-in (la respuesta la anota
    /// el modelo con goals.record_checkin).
    public static func chatPrompt(for goal: Goal) -> String {
        "¿Cómo vas con \(goal.statement)? Cuéntame y lo anoto."
    }
}
