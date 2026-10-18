// DurationText.swift — duraciones como las lee (y las oye) el dueño, en español:
// nunca "715 minutos" sino "11 horas y 55 minutos". Una sola fuente para la
// propuesta, los recordatorios, los widgets y la voz de CarPlay/Siri.

import Foundation

public enum DurationText {
    /// "45 minutos", "1 hora y 30 minutos", "2 horas", "1 día y 3 horas".
    public static func long(minutes: Int) -> String {
        let parts = split(minutes)
        if parts.days > 0 {
            return join(unit(parts.days, "día", "días"), parts.hours > 0 ? unit(parts.hours, "hora", "horas") : nil)
        }
        if parts.hours > 0 {
            return join(unit(parts.hours, "hora", "horas"),
                        parts.minutes > 0 ? unit(parts.minutes, "minuto", "minutos") : nil)
        }
        return unit(parts.minutes, "minuto", "minutos")
    }

    /// Espacios compactos (widgets): "45 min", "1 h 30 min", "2 h", "1 d 3 h".
    public static func compact(minutes: Int) -> String {
        let parts = split(minutes)
        if parts.days > 0 { return parts.hours > 0 ? "\(parts.days) d \(parts.hours) h" : "\(parts.days) d" }
        if parts.hours > 0 { return parts.minutes > 0 ? "\(parts.hours) h \(parts.minutes) min" : "\(parts.hours) h" }
        return "\(parts.minutes) min"
    }

    /// Para la voz: "media hora", "una hora y media", "2 horas y 15 minutos", "un día".
    public static func spoken(minutes: Int) -> String {
        let parts = split(minutes)
        if parts.days > 0 {
            return join(parts.days == 1 ? "un día" : "\(parts.days) días",
                        parts.hours > 0 ? spokenHours(parts.hours) : nil)
        }
        if parts.hours == 0 {
            switch parts.minutes {
            case 30: return "media hora"
            case 1: return "un minuto"
            default: return "\(parts.minutes) minutos"
            }
        }
        if parts.minutes == 30 { return "\(spokenHours(parts.hours)) y media" }
        return join(spokenHours(parts.hours), parts.minutes > 0 ? (parts.minutes == 1 ? "un minuto" : "\(parts.minutes) minutos") : nil)
    }

    private static func spokenHours(_ hours: Int) -> String {
        hours == 1 ? "una hora" : "\(hours) horas"
    }

    private static func split(_ minutes: Int) -> (days: Int, hours: Int, minutes: Int) {
        let total = max(0, minutes)
        let days = total / 1440
        guard days > 0 else { return (0, total / 60, total % 60) }
        let hours = Int((Double(total % 1440) / 60).rounded())
        return hours == 24 ? (days + 1, 0, 0) : (days, hours, 0)
    }

    private static func unit(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }

    private static func join(_ first: String, _ second: String?) -> String {
        second.map { "\(first) y \($0)" } ?? first
    }
}
