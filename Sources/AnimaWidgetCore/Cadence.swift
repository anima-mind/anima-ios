// Cadence.swift — cadencias compartidas por recordatorios y check-ins: datos
// puros que también lee la extensión de widgets (sin GRDB).

import Foundation

/// Cadencia compartida por recordatorios y check-ins.
public enum ProactiveCadence: String, Sendable, Codable, Equatable, CaseIterable {
    case none, daily, weekdays, weekly

    /// "cada día", "entre semana", "cada semana" (nil si no se repite).
    public var phrase: String? {
        switch self {
        case .none: return nil
        case .daily: return "cada día"
        case .weekdays: return "entre semana"
        case .weekly: return "cada semana"
        }
    }
}

extension ProactiveCadence {
    /// Próxima ocurrencia estrictamente posterior a `reference`, a la hora/minuto
    /// (y día de semana, si aplica) de `fireAt`. nil si no se repite.
    public func nextOccurrence(after reference: Date, of fireAt: Date, calendar: Calendar) -> Date? {
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: fireAt)
        func next(weekday: Int?) -> Date? {
            var c = DateComponents()
            c.hour = parts.hour
            c.minute = parts.minute
            c.second = 0
            c.weekday = weekday
            return calendar.nextDate(after: reference, matching: c, matchingPolicy: .nextTime)
        }
        switch self {
        case .none: return nil
        case .daily: return next(weekday: nil)
        case .weekly: return next(weekday: parts.weekday)
        case .weekdays: return (2...6).compactMap { next(weekday: $0) }.min()
        }
    }
}

/// Cada cuánto Anima le pregunta al dueño por una meta (opt-in, hora local).
public struct CheckInCadence: Sendable, Equatable, Codable {
    public static let defaultHour = 20

    public var cadence: ProactiveCadence
    public var hour: Int
    public var minute: Int
    /// Solo weekly: 1=domingo … 7=sábado.
    public var weekday: Int?

    public init(cadence: ProactiveCadence, hour: Int = CheckInCadence.defaultHour, minute: Int = 0,
                weekday: Int? = nil) {
        self.cadence = cadence
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
    }

    public static let off = CheckInCadence(cadence: .none)

    public var isActive: Bool { cadence != .none }

    public var isValid: Bool {
        (0...23).contains(hour) && (0...59).contains(minute)
            && (cadence != .weekly || (weekday.map { (1...7).contains($0) } ?? false))
    }

    /// "cada día a las 20:00", "entre semana a las 07:30", "cada lunes a las 09:00".
    public var phrase: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch cadence {
        case .none: return "sin check-in"
        case .daily: return "cada día a las \(time)"
        case .weekdays: return "entre semana a las \(time)"
        case .weekly: return "cada \(Self.weekdayName(weekday ?? 2)) a las \(time)"
        }
    }

    public static func weekdayName(_ weekday: Int) -> String {
        let names = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"]
        return names[(max(1, min(7, weekday))) - 1]
    }
}
