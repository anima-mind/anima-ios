// WidgetTimeline.swift — cuándo debe repintarse un widget sin que la app
// corra: cada 15 min en las próximas 2 h (la hora relativa "en 25 min"), al
// llegar cada recordatorio y seguimiento de las próximas 24 h y a medianoche.

import Foundation

public enum WidgetTimeline {
    public static let maxEntries = 60

    public static func entryDates(for snapshot: WidgetSnapshot, from now: Date,
                                  calendar: Calendar = .current) -> [Date] {
        let horizon = now.addingTimeInterval(24 * 3600)
        var dates: Set<Date> = [now]
        for step in 1...8 { dates.insert(now.addingTimeInterval(TimeInterval(step) * 15 * 60)) }
        let today = calendar.startOfDay(for: now)
        for offset in 1...2 {
            if let midnight = calendar.date(byAdding: .day, value: offset, to: today) { dates.insert(midnight) }
        }
        for offset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            for reminder in snapshot.reminders where !reminder.delivered {
                dates.insert(WidgetSnapshot.occurrence(of: reminder, from: day, calendar: calendar))
            }
            for goal in snapshot.goals {
                if let at = WidgetSnapshot.checkInTime(goal.checkIn, on: day, calendar: calendar) { dates.insert(at) }
            }
        }
        return Array(dates.filter { $0 >= now && $0 <= horizon }.sorted().prefix(maxEntries))
    }
}
