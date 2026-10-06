// ProactiveCard.swift — cómo se ve en el chat lo que ella dice sin que se lo
// pidan: ícono por tipo, etiqueta ("Recordatorio · hoy 8:30 p. m.",
// "Check-in · <meta>", "Propuesta") y el seguimiento "¿Cómo te fue?" solo
// cuando el aviso ya quedó atrás.

import Foundation

public enum ProactiveCard {
    public static let followUp = "¿Cómo te fue?"
    /// Tiempo tras la hora del recordatorio para preguntar cómo le fue.
    public static let followUpDelay: TimeInterval = 60 * 60

    /// SF Symbol del ícono a la izquierda de la card.
    public static func symbol(_ kind: ProactiveMessage.Kind) -> String {
        switch kind {
        case .reminder: return "bell.fill"
        case .checkIn: return "target"
        case .intention: return "sparkles"
        }
    }

    public static func label(_ kind: ProactiveMessage.Kind, at: Date?, goalStatement: String?, now: Date,
                             dates: AnimaDateText) -> String {
        switch kind {
        case .reminder:
            return at.map { "Recordatorio · \(dates.moment($0, now: now))" } ?? "Recordatorio"
        case .checkIn:
            return goalStatement.map { "Check-in · \($0)" } ?? "Check-in"
        case .intention:
            return "Propuesta"
        }
    }

    /// "¿Cómo te fue?" solo en recordatorios cuya hora pasó hace ≥ `followUpDelay`.
    public static func followUp(_ kind: ProactiveMessage.Kind, at: Date?, now: Date) -> String? {
        guard case .reminder = kind, let at, now.timeIntervalSince(at) >= followUpDelay else { return nil }
        return followUp
    }
}
