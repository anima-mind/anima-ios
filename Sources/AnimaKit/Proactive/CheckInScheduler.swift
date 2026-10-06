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

    /// Ella preguntando, no un sistema: "Oye, ¿cómo vas con ahorrar 10M?".
    public static func body(for goal: Goal) -> String {
        "Oye, ¿cómo vas con \(inline(goal.statement))?"
    }

    /// Lo que Anima dice en el chat al abrir el check-in (la respuesta la anota
    /// el modelo con goals.record_checkin).
    public static func chatPrompt(for goal: Goal) -> String {
        "Oye, ¿cómo vas con \(inline(goal.statement))? Cuéntame y lo anoto."
    }

    /// La meta dentro de una frase: "Ahorrar 10M" → "ahorrar 10M" (no toca
    /// siglas ni nombres propios: solo si la segunda letra es minúscula).
    static func inline(_ statement: String) -> String {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first.isUppercase else { return trimmed }
        let rest = trimmed.dropFirst()
        guard let second = rest.first, second.isLowercase else { return trimmed }
        return first.lowercased() + rest
    }
}
