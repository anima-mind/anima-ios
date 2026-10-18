// ProposalSlot.swift — de un hueco libre del calendario a UNA sesión razonable
// para la propuesta del deseo: arranca en :00/:30 y dura a lo sumo una hora.
// El hueco crudo ("domingo 18 a las 09:04 (715min)", de ahora a las 21:00) se
// le pasaba al modelo y él lo copiaba tal cual. Y lo que el modelo redacta se
// valida antes de mostrarlo: duraciones absurdas u horas sueltas no pasan.

import Foundation
import AnimaWidgetCore

public struct ProposalSlot: Sendable, Equatable {
    public var start: Date
    public var minutes: Int

    public static let sessionMinutes = 60
    public static let shortestMinutes = 30
    public static let granularity = 30

    public init(start: Date, minutes: Int) {
        self.start = start
        self.minutes = minutes
    }

    /// El primer hueco donde cabe una sesión de ≥30 min empezando en :00/:30.
    public static func pick(from slots: [DateInterval], now: Date, calendar: Calendar = .current) -> ProposalSlot? {
        for slot in slots.sorted(by: { $0.start < $1.start }) {
            let start = roundUp(max(slot.start, now), calendar: calendar)
            let available = Int(slot.end.timeIntervalSince(start) / 60)
            let minutes = min(sessionMinutes, available / 15 * 15)
            if minutes >= shortestMinutes { return ProposalSlot(start: start, minutes: minutes) }
        }
        return nil
    }

    static func roundUp(_ date: Date, calendar: Calendar) -> Date {
        guard let floored = calendar.dateInterval(of: .minute, for: date)?.start else { return date }
        let minute = calendar.component(.minute, from: floored)
        let into = minute % granularity
        if into == 0, floored == date { return date }
        return calendar.date(byAdding: .minute, value: granularity - into, to: floored) ?? date
    }

    /// "domingo 18 a las 9:30 a. m."
    public func phrase(calendar: Calendar = .current) -> String {
        let weekday = calendar.component(.weekday, from: start)
        let day = calendar.component(.day, from: start)
        return "\(AnimaDateText.weekdays[weekday - 1]) \(day) a las \(AnimaDateText(calendar: calendar).time(start))"
    }

    /// "1 hora el domingo 18 a las 9:30 a. m."
    public func summary(calendar: Calendar = .current) -> String {
        "\(DurationText.long(minutes: minutes)) el \(phrase(calendar: calendar))"
    }
}

/// Lo que redacta el modelo para una propuesta, validado antes de mostrarlo.
public enum ProposalText {
    /// Más que esto no es "una sesión" para avanzar en una meta.
    public static let longestMinutes = 180

    static let duration = ICURegex(#"\b(\d{1,5}) ?(minutos|minuto|mins|min|horas|hora|hrs|hr|h)\b"#, caseInsensitive: true)
    static let clock = ICURegex(#"\b([01]?\d|2[0-3]):([0-5]\d)\b"#)

    /// El texto con sus duraciones en formato humano, o nil si trae una cifra
    /// absurda (más de 3 horas) o una hora que no cae en un cuarto de hora.
    public static func validated(_ text: String) -> String? {
        for match in clock.matches(in: text) {
            guard let minute = match[2].flatMap({ Int($0) }), minute % 15 == 0 else { return nil }
        }
        var out = ""
        var cursor = text.startIndex
        for match in duration.matches(in: text) {
            guard let value = match[1].flatMap({ Int($0) }), let unit = match[2] else { continue }
            let minutes = unit.lowercased().hasPrefix("h") ? value * 60 : value
            guard minutes > 0, minutes <= longestMinutes else { return nil }
            out += text[cursor..<match.range.lowerBound]
            out += DurationText.long(minutes: minutes)
            cursor = match.range.upperBound
        }
        out += text[cursor...]
        return out
    }
}
