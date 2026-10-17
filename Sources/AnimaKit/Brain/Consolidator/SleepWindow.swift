// SleepWindow.swift — "Hora de dormir" (Ajustes → Mente): el rango en hora
// local del teléfono en que el sueño puede correr (default 01:00–06:00). Se
// evalúa siempre contra el Calendar que se le pase (en la app,
// `.autoupdatingCurrent`), nunca contra una zona congelada: un viaje o un
// cambio de horario mueven la ventana con el reloj de pared.

import Foundation

public struct SleepWindow: Sendable, Equatable, Hashable {
    public struct Time: Sendable, Equatable, Hashable, Comparable {
        public let hour: Int
        public let minute: Int

        public init(hour: Int, minute: Int = 0) {
            self.hour = min(max(hour, 0), 23)
            self.minute = min(max(minute, 0), 59)
        }

        public init(minutesOfDay: Int) {
            let wrapped = ((minutesOfDay % Self.day) + Self.day) % Self.day
            self.init(hour: wrapped / 60, minute: wrapped % 60)
        }

        public var minutesOfDay: Int { hour * 60 + minute }

        public var label: String { String(format: "%02d:%02d", hour, minute) }

        public static func < (lhs: Time, rhs: Time) -> Bool { lhs.minutesOfDay < rhs.minutesOfDay }

        static let day = 24 * 60
    }

    public let start: Time
    public let end: Time

    public static let `default` = SleepWindow(start: Time(hour: 1), end: Time(hour: 6))
    public static let minimumMinutes = 60
    public static let maximumMinutes = 12 * 60

    public init(start: Time, end: Time) {
        self.start = start
        self.end = end
    }

    public var durationMinutes: Int {
        (end.minutesOfDay - start.minutesOfDay + Time.day) % Time.day
    }

    public var crossesMidnight: Bool { end <= start }

    public var isValid: Bool {
        (Self.minimumMinutes...Self.maximumMinutes).contains(durationMinutes)
    }

    public var label: String { "\(start.label)–\(end.label)" }

    /// Inicio incluido, fin excluido, sobre la hora de pared del `calendar`.
    public func contains(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if crossesMidnight {
            return minutes >= start.minutesOfDay || minutes < end.minutesOfDay
        }
        return minutes >= start.minutesOfDay && minutes < end.minutesOfDay
    }

    /// El próximo inicio estrictamente posterior a `date`. Si el inicio cae en
    /// el hueco de un cambio de horario (no existe ese día), se toma la primera
    /// hora válida después.
    public func nextStart(after date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let matching = DateComponents(hour: start.hour, minute: start.minute, second: 0)
        return calendar.nextDate(after: date, matching: matching, matchingPolicy: .nextTime,
                                 repeatedTimePolicy: .first, direction: .forward)
            ?? date.addingTimeInterval(24 * 3600)
    }

    /// El inicio de la ocurrencia de la ventana que contiene `date` (nil si no la contiene).
    public func currentStart(containing date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        guard contains(date, calendar: calendar) else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let startedYesterday = crossesMidnight && minutes < end.minutesOfDay
        let day = calendar.startOfDay(for: date)
        let base = startedYesterday ? (calendar.date(byAdding: .day, value: -1, to: day) ?? day) : day
        let candidate = calendar.nextDate(after: base.addingTimeInterval(-1),
                                          matching: DateComponents(hour: start.hour, minute: start.minute, second: 0),
                                          matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
        return candidate ?? base
    }
}

/// "Hora de dormir" persistida (UserDefaults), con el patrón de WakePreference.
/// Lo persistido fuera de rango (o a medias) cae al default.
public final class SleepWindowPreference: @unchecked Sendable {
    public static let startKey = "anima.sleep.windowStart"
    public static let endKey = "anima.sleep.windowEnd"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var window: SleepWindow {
        guard let start = defaults.object(forKey: Self.startKey) as? Int,
              let end = defaults.object(forKey: Self.endKey) as? Int,
              (0..<SleepWindow.Time.day).contains(start), (0..<SleepWindow.Time.day).contains(end) else {
            return .default
        }
        let window = SleepWindow(start: .init(minutesOfDay: start), end: .init(minutesOfDay: end))
        return window.isValid ? window : .default
    }

    /// false (y nada cambia) si el rango no dura entre 1 y 12 horas.
    @discardableResult
    public func set(_ window: SleepWindow) -> Bool {
        guard window.isValid else { return false }
        defaults.set(window.start.minutesOfDay, forKey: Self.startKey)
        defaults.set(window.end.minutesOfDay, forKey: Self.endKey)
        return true
    }
}
