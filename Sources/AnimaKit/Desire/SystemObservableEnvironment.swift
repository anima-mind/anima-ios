// SystemObservableEnvironment.swift — la evaluación real de los Observables (§5.8)
// contra el cuerpo iOS de Fase 1: calendario y recordatorios vía EventKit. Todo
// LOCAL y barato (0 LLM). Sueño y "días desde última mención" quedan device-pending
// (HealthKit / Brain-FTS): degradan a nil, que los predicados tratan sin gap falso.

import Foundation

/// Ventana horaria "razonable" para buscar huecos (evita proponer las 3am).
private let dayStartHour = 8
private let dayEndHour = 21
private let workoutKeywords = ["entren", "gym", "gimnasio", "workout", "correr", "run", "pesas", "yoga"]

public struct SystemObservableEnvironment: ObservableEnvironment {
    public init() {}

    public func workoutsThisWeek() async -> Int {
        #if canImport(EventKit)
        return await EventKitObservables.workoutsThisWeek(keywords: workoutKeywords)
        #else
        return 0
        #endif
    }

    public func overdueReminderCount() async -> Int {
        #if canImport(EventKit)
        return await EventKitObservables.overdueReminderCount()
        #else
        return 0
        #endif
    }

    public func averageSleepHours(lastDays: Int) async -> Double? {
        // HealthKit read-only agregado: device-pending (§5.7). nil ⇒ sin gap falso.
        nil
    }

    public func freeSlots(minMinutes: Int, withinDays: Int) async -> [DateInterval] {
        #if canImport(EventKit)
        return await EventKitObservables.freeSlots(minMinutes: minMinutes, withinDays: withinDays,
                                                   dayStartHour: dayStartHour, dayEndHour: dayEndHour)
        #else
        return []
        #endif
    }

    public func daysSinceLastMention(topic: String) async -> Int? {
        // Requiere el Brain (FTS) para fechar la última mención: device-pending.
        nil
    }
}

#if canImport(EventKit)
import EventKit

enum EventKitObservables {
    static func workoutsThisWeek(keywords: [String]) async -> Int {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true else { return 0 }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        return events.filter { event in
            let title = (event.title ?? "").lowercased()
            return keywords.contains { title.contains($0) }
        }.count
    }

    static func overdueReminderCount() async -> Int {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToReminders()) == true else { return 0 }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: Date(), calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).count)
            }
        }
    }

    /// Huecos libres de al menos `minMinutes` dentro de la ventana diaria, para los
    /// próximos `withinDays` días. Barrido determinístico sobre los eventos.
    static func freeSlots(minMinutes: Int, withinDays: Int, dayStartHour: Int, dayEndHour: Int) async -> [DateInterval] {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true else { return [] }
        let cal = Calendar.current
        let now = Date()
        let end = cal.date(byAdding: .day, value: max(1, withinDays), to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let busy = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        var slots: [DateInterval] = []
        let minDuration = TimeInterval(minMinutes * 60)
        for offset in 0..<max(1, withinDays) {
            guard let day = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            guard let windowStart = cal.date(bySettingHour: dayStartHour, minute: 0, second: 0, of: day),
                  let windowEnd = cal.date(bySettingHour: dayEndHour, minute: 0, second: 0, of: day) else { continue }
            var cursor = max(windowStart, now)
            let dayEvents = busy.filter { $0.startDate < windowEnd && $0.endDate > windowStart }
            for event in dayEvents {
                if event.startDate.timeIntervalSince(cursor) >= minDuration {
                    slots.append(DateInterval(start: cursor, end: event.startDate))
                }
                cursor = max(cursor, event.endDate)
            }
            if windowEnd.timeIntervalSince(cursor) >= minDuration {
                slots.append(DateInterval(start: cursor, end: windowEnd))
            }
        }
        return slots
    }
}
#endif
