// AnimaDateText.swift — fechas y horas como las dice ella (es_CO), deterministas:
// sin depender del ICU de cada sistema ("p.m." vs "p. m."). Calendario
// inyectable; `now` siempre explícito (tests con reloj fijo).

import Foundation

public struct AnimaDateText: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    package static let weekdays = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"]
    package static let weekdaysShort = ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"]
    package static let months = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
                         "septiembre", "octubre", "noviembre", "diciembre"]
    package static let monthsShort = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]

    /// "8:30 p. m." / "9:05 a. m." / "12:00 p. m.".
    public func time(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve):\(minute < 10 ? "0" : "")\(minute) \(hour < 12 ? "a. m." : "p. m.")"
    }

    /// Días de calendario entre `date` y `now` (positivo = pasado).
    public func daysAgo(_ date: Date, now: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                to: calendar.startOfDay(for: now)).day ?? 0
    }

    /// Separador del chat (como WhatsApp): "Hoy", "Ayer" o "lunes 5 de octubre"
    /// (+ " de 2025" si no es este año).
    public func dayHeader(_ date: Date, now: Date) -> String {
        switch daysAgo(date, now: now) {
        case 0: return "Hoy"
        case 1: return "Ayer"
        default: return fullDate(date, now: now)
        }
    }

    /// "lunes 5 de octubre" (+ año si difiere del de `now`).
    public func fullDate(_ date: Date, now: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let base = "\(Self.weekdays[(parts.weekday ?? 1) - 1]) \(parts.day ?? 1) de \(Self.months[(parts.month ?? 1) - 1])"
        let year = calendar.component(.year, from: now)
        return parts.year == year ? base : "\(base) de \(parts.year ?? year)"
    }

    /// Cuándo pasa (o pasó) algo: "hoy 8:30 p. m.", "mañana 9:00 a. m.",
    /// "ayer 8:30 p. m." o "lun 12 oct, 9:00 a. m.".
    public func moment(_ date: Date, now: Date) -> String {
        let clock = time(date)
        switch daysAgo(date, now: now) {
        case 0: return "hoy \(clock)"
        case 1: return "ayer \(clock)"
        case -1: return "mañana \(clock)"
        default: return shortMoment(date)
        }
    }

    /// "jue 8 oct, 3:00 p. m." — sin relativos (no depende de `now`).
    public func shortMoment(_ date: Date) -> String {
        let parts = calendar.dateComponents([.month, .day, .weekday], from: date)
        return "\(Self.weekdaysShort[(parts.weekday ?? 1) - 1]) \(parts.day ?? 1) "
            + "\(Self.monthsShort[(parts.month ?? 1) - 1]), \(time(date))"
    }

    /// ISO 8601 con fecha y hora, con o sin offset y con o sin fracción de
    /// segundo. Sin offset ⇒ hora local del calendario. Solo fecha o basura ⇒ nil.
    public func parseISODateTime(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let withOffset: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
        ]
        for options in withOffset {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.calendar = Calendar(identifier: .gregorian)
        local.timeZone = calendar.timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }

    /// Fecha ISO que propone el modelo, legible para el dueño ("jue 8 oct,
    /// 3:00 p. m."); si no parsea, el texto tal cual.
    public func readableISO(_ raw: String) -> String {
        parseISODateTime(raw).map(shortMoment) ?? raw
    }
}
