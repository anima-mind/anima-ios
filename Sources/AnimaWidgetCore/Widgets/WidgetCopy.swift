// WidgetCopy.swift — todo el texto de los widgets, en su voz y en español
// (deterministas: sin depender del idioma del sistema ni del ICU).

import Foundation

public struct WidgetCopy: Sendable {
    public static let emptyToday = "Nada pendiente hoy"
    public static let emptyHint = "Si quieres que te recuerde algo, dímelo."
    public static let noGoals = "Aún no tienes metas"
    public static let noGoalsHint = "Cuéntame qué quieres lograr."
    public static let done = "Hecho"
    public static let progressed = "Sí, avancé"
    public static let talk = "Hablar con Anima"
    public static let followUp = "Seguimiento"
    public static let nextLabel = "Próximo"

    public var dates: AnimaDateText

    public init(calendar: Calendar = .current) {
        dates = AnimaDateText(calendar: calendar)
    }

    /// "9:00" — hora corta para espacios chicos (a. m./p. m. solo si hace falta).
    public func clock(_ date: Date) -> String {
        let parts = dates.calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve):\(minute < 10 ? "0" : "")\(minute)"
    }

    /// "en 25 min", "en 2 h", "hace 10 min", "ahora", "mañana 9:00 a. m.".
    public func relative(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        let minutes = Int((abs(seconds) / 60).rounded())
        if minutes < 1 { return "ahora" }
        let sameDay = dates.calendar.isDate(date, inSameDayAs: now)
        if seconds < 0 {
            if minutes < 60 { return "hace \(minutes) min" }
            return sameDay ? "a las \(dates.time(date))" : dates.moment(date, now: now)
        }
        if minutes < 60 { return "en \(minutes) min" }
        if sameDay {
            let hours = minutes / 60
            return hours < 3 ? "en \(hours) h" : "a las \(dates.time(date))"
        }
        return dates.moment(date, now: now)
    }

    /// Pantalla de bloqueo (inline): "Próximo: llamar al banco · 9:00".
    public func lockLine(_ day: WidgetDay) -> String {
        guard let next = day.next else { return Self.emptyToday }
        let when = dates.calendar.isDate(next.at, inSameDayAs: day.now)
            ? clock(next.at) : dates.moment(next.at, now: day.now)
        return "\(Self.nextLabel): \(Self.inline(next.text)) · \(when)"
    }

    /// "Racha de 4 días" / "Racha de 1 día" / "Sin racha aún".
    public func streak(_ days: Int) -> String {
        switch days {
        case ..<1: return "Sin racha aún"
        case 1: return "Racha de 1 día"
        default: return "Racha de \(days) días"
        }
    }

    /// "Próximo seguimiento: hoy 8:00 p. m." / "Sin seguimiento".
    public func nextFollowUp(_ date: Date?, now: Date) -> String {
        guard let date else { return "Sin seguimiento" }
        return "Próximo seguimiento: \(dates.moment(date, now: now))"
    }

    /// "Noche 12" (o "Recién nacida" sin noches).
    public func nights(_ count: Int) -> String {
        count < 1 ? "Recién nacida" : "Noche \(count)"
    }

    /// Live Activity del sueño.
    public static func consolidating(_ name: String) -> String { "\(name) está consolidando…" }
    public static func nightReady(_ number: Int) -> String { "Noche #\(number) lista" }

    /// La primera letra en minúscula dentro de una frase ("Llamar" → "llamar"),
    /// salvo siglas/nombres propios (segunda letra mayúscula).
    public static func inline(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first.isUppercase else { return trimmed }
        let rest = trimmed.dropFirst()
        guard let second = rest.first, second.isLowercase else { return trimmed }
        return first.lowercased() + rest
    }
}
