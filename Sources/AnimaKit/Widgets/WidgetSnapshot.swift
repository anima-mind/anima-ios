// WidgetSnapshot.swift — lo ÚNICO que lee la extensión de widgets: un JSON
// ligero en el App Group que la app reescribe tras cada cambio relevante. El
// widget jamás abre GRDB (sin locks compartidos con la app). El snapshot guarda
// hechos (fechas, cadencias, rachas); el "hoy" se proyecta en cada entrada del
// timeline con `day(at:)`, así sigue correcto al cruzar medianoche sin la app.

import Foundation

public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct Reminder: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var text: String
        public var fireAt: Date
        public var cadence: ProactiveCadence
        /// Ya entregado hoy y sin "Hecho" (uno-a-uno en estado fired).
        public var delivered: Bool
        public var goalId: String?

        public init(id: String, text: String, fireAt: Date, cadence: ProactiveCadence = .none,
                    delivered: Bool = false, goalId: String? = nil) {
            self.id = id
            self.text = text
            self.fireAt = fireAt
            self.cadence = cadence
            self.delivered = delivered
            self.goalId = goalId
        }
    }

    public struct Goal: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var statement: String
        public var checkIn: CheckInCadence
        /// Racha al generar + el último día con avance (para proyectarla otro día).
        public var streak: Int
        public var lastProgressAt: Date?
        public var lastAnsweredAt: Date?

        public init(id: String, statement: String, checkIn: CheckInCadence = .off, streak: Int = 0,
                    lastProgressAt: Date? = nil, lastAnsweredAt: Date? = nil) {
            self.id = id
            self.statement = statement
            self.checkIn = checkIn
            self.streak = streak
            self.lastProgressAt = lastProgressAt
            self.lastAnsweredAt = lastAnsweredAt
        }
    }

    public var version: Int
    public var generatedAt: Date
    public var selfName: String
    public var plasticity: Double
    public var nights: Int
    /// Programados (por fecha) + entregados sin cerrar.
    public var reminders: [Reminder]
    /// Metas que motivan, en el orden del deseo.
    public var goals: [Goal]

    public init(generatedAt: Date, selfName: String, plasticity: Double, nights: Int,
                reminders: [Reminder], goals: [Goal], version: Int = WidgetSnapshot.currentVersion) {
        self.version = version
        self.generatedAt = generatedAt
        self.selfName = selfName
        self.plasticity = plasticity
        self.nights = nights
        self.reminders = reminders
        self.goals = goals
    }

    /// Sin app abierta nunca: el widget muestra la marca y el vacío amable.
    public static func placeholder(now: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: now, selfName: "Anima", plasticity: 1, nights: 0, reminders: [], goals: [])
    }

    /// Datos de ejemplo de la galería de widgets (sin datos del dueño).
    public static func sample(now: Date = Date(), calendar: Calendar = .current) -> WidgetSnapshot {
        let today = calendar.startOfDay(for: now)
        func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        let next = max(now.addingTimeInterval(25 * 60), at(9))
        return WidgetSnapshot(
            generatedAt: now, selfName: "Budosky", plasticity: 0.62, nights: 12,
            reminders: [
                Reminder(id: "sample-1", text: "Llamar al banco", fireAt: next),
                Reminder(id: "sample-2", text: "Pagar la tarjeta", fireAt: at(18, 30)),
            ],
            goals: [
                Goal(id: "sample-goal", statement: "Ahorrar 10M para invertir",
                     checkIn: CheckInCadence(cadence: .daily, hour: 20, minute: 0), streak: 4,
                     lastProgressAt: at(20, dayOffset: -1)),
                Goal(id: "sample-goal-2", statement: "Correr 3 veces por semana",
                     checkIn: CheckInCadence(cadence: .weekly, hour: 9, minute: 0, weekday: 1), streak: 0),
            ])
    }
}

// MARK: - Proyección del día

/// Lo que un widget pinta en un instante: derivado del snapshot, puro.
public struct WidgetDay: Equatable, Sendable {
    public struct ReminderLine: Equatable, Sendable, Identifiable {
        public var id: String
        public var text: String
        public var at: Date
        public var overdue: Bool
    }

    public struct CheckInLine: Equatable, Sendable, Identifiable {
        public var id: String { goalId }
        public var goalId: String
        public var statement: String
        public var at: Date
        public var answered: Bool
    }

    public struct GoalLine: Equatable, Sendable, Identifiable {
        public var id: String
        public var statement: String
        public var streak: Int
        public var nextCheckIn: Date?
    }

    public var now: Date
    public var selfName: String
    public var plasticity: Double
    public var nights: Int
    /// El próximo recordatorio aún por llegar (cualquier día).
    public var next: ReminderLine?
    /// Recordatorios de hoy (incluye los entregados sin cerrar), por hora.
    public var reminders: [ReminderLine]
    /// Seguimientos que tocan hoy, por hora.
    public var checkIns: [CheckInLine]
    public var goals: [GoalLine]

    /// "Nada pendiente hoy": ni recordatorios abiertos ni seguimientos sin responder.
    public var isEmpty: Bool {
        reminders.isEmpty && !checkIns.contains { !$0.answered }
    }

    /// El seguimiento que importa ahora: el primero sin responder.
    public var pendingCheckIn: CheckInLine? { checkIns.first { !$0.answered } }

    public func goal(id: String?) -> GoalLine? {
        guard let id else { return goals.first }
        return goals.first { $0.id == id }
    }
}

extension WidgetSnapshot {
    public func day(at now: Date, calendar: Calendar = .current) -> WidgetDay {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(86_400)

        var today: [WidgetDay.ReminderLine] = []
        var upcoming: [WidgetDay.ReminderLine] = []
        for reminder in reminders {
            let at = Self.occurrence(of: reminder, from: start, calendar: calendar)
            let line = WidgetDay.ReminderLine(id: reminder.id, text: reminder.text, at: at, overdue: at < now)
            if reminder.delivered {
                if at >= start { today.append(line) }
                continue
            }
            if at >= start, at < end { today.append(line) }
            if at >= now { upcoming.append(line) }
        }
        today.sort { $0.at < $1.at }
        upcoming.sort { $0.at < $1.at }

        var checkIns: [WidgetDay.CheckInLine] = []
        var goalLines: [WidgetDay.GoalLine] = []
        for goal in goals {
            let answeredToday = goal.lastAnsweredAt.map { $0 >= start } ?? false
            if let at = Self.checkInTime(goal.checkIn, on: start, calendar: calendar) {
                checkIns.append(.init(goalId: goal.id, statement: goal.statement, at: at, answered: answeredToday))
            }
            goalLines.append(.init(id: goal.id, statement: goal.statement,
                                   streak: Self.streak(of: goal, at: now, calendar: calendar),
                                   nextCheckIn: Self.nextCheckIn(goal.checkIn, after: now, skipToday: answeredToday,
                                                                 calendar: calendar)))
        }
        checkIns.sort { $0.at < $1.at }

        return WidgetDay(now: now, selfName: selfName, plasticity: plasticity, nights: nights,
                         next: upcoming.first, reminders: today, checkIns: checkIns, goals: goalLines)
    }

    /// La ocurrencia vigente: un recordatorio que se repite y cuya fecha quedó
    /// antes de hoy (la app no lo ha reconciliado) rueda a hoy o después.
    static func occurrence(of reminder: Reminder, from start: Date, calendar: Calendar) -> Date {
        guard reminder.cadence != .none, reminder.fireAt < start, !reminder.delivered else { return reminder.fireAt }
        let probe = start.addingTimeInterval(-1)
        return AnimaReminderStore.nextOccurrence(after: probe, of: reminder.fireAt, repeat: reminder.cadence,
                                                 calendar: calendar) ?? reminder.fireAt
    }

    /// Hora del seguimiento si toca el día `start` (nil si no toca o no hay).
    static func checkInTime(_ checkIn: CheckInCadence, on start: Date, calendar: Calendar) -> Date? {
        guard checkIn.isActive, checkIn.isValid else { return nil }
        let weekday = calendar.component(.weekday, from: start)
        switch checkIn.cadence {
        case .none: return nil
        case .daily: break
        case .weekdays: guard (2...6).contains(weekday) else { return nil }
        case .weekly: guard weekday == (checkIn.weekday ?? 2) else { return nil }
        }
        return calendar.date(bySettingHour: checkIn.hour, minute: checkIn.minute, second: 0, of: start)
    }

    /// Próximo seguimiento posterior a `now` (si ya respondió hoy, desde mañana).
    static func nextCheckIn(_ checkIn: CheckInCadence, after now: Date, skipToday: Bool,
                            calendar: Calendar) -> Date? {
        guard checkIn.isActive, checkIn.isValid else { return nil }
        var day = calendar.startOfDay(for: now)
        for _ in 0..<8 {
            if let at = checkInTime(checkIn, on: day, calendar: calendar), at > now,
               !(skipToday && calendar.isDate(at, inSameDayAs: now)) {
                return at
            }
            guard let following = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = following
        }
        return nil
    }

    /// La racha sigue viva si el último avance fue hoy o ayer respecto a `now`.
    static func streak(of goal: Goal, at now: Date, calendar: Calendar) -> Int {
        guard goal.streak > 0, let last = goal.lastProgressAt else { return 0 }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: last),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        return days <= 1 ? goal.streak : 0
    }
}
