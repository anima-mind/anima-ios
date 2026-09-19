// Observables.swift — predicados observables tipados (§5.8). Decisión fijada:
// ObservablePredicate es un enum CERRADO, no strings evaluados por el modelo —
// el deseo crece con el cuerpo (release), no con el prompt. Cada caso se evalúa
// BARATO y local (0 LLM) contra un ObservableEnvironment: en producción los
// providers reales (EventKit/HealthKit vía las tools de Fase 1), en tests un mock.

import Foundation

/// La superficie que un predicado consulta para saber si la realidad avanza hacia
/// la meta. Todo local y barato; ninguna llamada a LLM. En producción lo implementa
/// SystemObservableEnvironment (EventKit); en tests, MockObservableEnvironment.
public protocol ObservableEnvironment: Sendable {
    func workoutsThisWeek() async -> Int
    func overdueReminderCount() async -> Int
    func averageSleepHours(lastDays: Int) async -> Double?
    func freeSlots(minMinutes: Int, withinDays: Int) async -> [DateInterval]
    func daysSinceLastMention(topic: String) async -> Int?
}

/// Lectura de un predicado contra el entorno: satisfecho o no, con un detalle
/// legible que alimenta el prompt del drive y el log de la Intention.
public struct ObservableReading: Sendable, Equatable {
    public var satisfied: Bool
    public var detail: String
    public init(satisfied: Bool, detail: String) {
        self.satisfied = satisfied
        self.detail = detail
    }
}

/// Enum cerrado de predicados evaluables sin LLM contra el estado del teléfono
/// (§5.8). Agregar un caso = release de la app. El `kind` de su JSON es el mismo
/// vocabulario que se le ofrece a Haiku al extraer metas del ciclo.
public enum ObservablePredicate: Sendable, Equatable {
    case workoutsPerWeek(atLeast: Int)
    case remindersOverdue(atMost: Int)
    case sleepHours(atLeast: Double, lastDays: Int)
    case calendarFreeSlot(minMinutes: Int, withinDays: Int)
    case daysSinceLastMention(topic: String, atMost: Int)

    public var label: String {
        switch self {
        case .workoutsPerWeek(let n): return "entrenar al menos \(n)x por semana"
        case .remindersOverdue(let n): return "no más de \(n) recordatorios vencidos"
        case .sleepHours(let h, let d): return "dormir al menos \(h)h (últimos \(d) días)"
        case .calendarFreeSlot(let m, let d): return "reservar un hueco de \(m)min en \(d) días"
        case .daysSinceLastMention(let t, let n): return "retomar '\(t)' cada \(n) días"
        }
    }

    /// Evaluación local (0 LLM): la corre el DesireEngine antes de gastar un pulso.
    public func evaluate(in env: ObservableEnvironment) async -> ObservableReading {
        switch self {
        case .workoutsPerWeek(let n):
            let w = await env.workoutsThisWeek()
            return ObservableReading(satisfied: w >= n, detail: "entrenamientos esta semana: \(w) de \(n)")
        case .remindersOverdue(let n):
            let c = await env.overdueReminderCount()
            return ObservableReading(satisfied: c <= n, detail: "recordatorios vencidos: \(c) (máximo \(n))")
        case .sleepHours(let h, let d):
            guard let avg = await env.averageSleepHours(lastDays: d) else {
                return ObservableReading(satisfied: true, detail: "sin datos de sueño")
            }
            return ObservableReading(satisfied: avg >= h,
                                     detail: String(format: "sueño promedio %.1fh (meta %.1fh)", avg, h))
        case .calendarFreeSlot(let m, let d):
            let slots = await env.freeSlots(minMinutes: m, withinDays: d)
            return ObservableReading(satisfied: !slots.isEmpty,
                                     detail: slots.isEmpty ? "sin huecos de \(m)min en \(d) días"
                                                           : "\(slots.count) huecos de \(m)min disponibles")
        case .daysSinceLastMention(let t, let n):
            guard let days = await env.daysSinceLastMention(topic: t) else {
                return ObservableReading(satisfied: false, detail: "nunca se mencionó '\(t)'")
            }
            return ObservableReading(satisfied: days <= n, detail: "\(days) días desde '\(t)' (máximo \(n))")
        }
    }
}

extension ObservablePredicate: Codable {
    private enum K: String, CodingKey {
        case kind, value, hours
        case lastDays = "last_days"
        case minMinutes = "min_minutes"
        case withinDays = "within_days"
        case topic, days
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .workoutsPerWeek(let n):
            try c.encode("workouts_per_week", forKey: .kind)
            try c.encode(n, forKey: .value)
        case .remindersOverdue(let n):
            try c.encode("reminders_overdue_at_most", forKey: .kind)
            try c.encode(n, forKey: .value)
        case .sleepHours(let h, let d):
            try c.encode("sleep_hours_at_least", forKey: .kind)
            try c.encode(h, forKey: .hours)
            try c.encode(d, forKey: .lastDays)
        case .calendarFreeSlot(let m, let d):
            try c.encode("calendar_has_free_slot", forKey: .kind)
            try c.encode(m, forKey: .minMinutes)
            try c.encode(d, forKey: .withinDays)
        case .daysSinceLastMention(let t, let n):
            try c.encode("days_since_last_mention_at_most", forKey: .kind)
            try c.encode(t, forKey: .topic)
            try c.encode(n, forKey: .days)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "workouts_per_week":
            self = .workoutsPerWeek(atLeast: try c.decode(Int.self, forKey: .value))
        case "reminders_overdue_at_most":
            self = .remindersOverdue(atMost: try c.decode(Int.self, forKey: .value))
        case "sleep_hours_at_least":
            self = .sleepHours(atLeast: try c.decode(Double.self, forKey: .hours),
                               lastDays: try c.decodeIfPresent(Int.self, forKey: .lastDays) ?? 7)
        case "calendar_has_free_slot":
            self = .calendarFreeSlot(minMinutes: try c.decode(Int.self, forKey: .minMinutes),
                                     withinDays: try c.decodeIfPresent(Int.self, forKey: .withinDays) ?? 7)
        case "days_since_last_mention_at_most":
            self = .daysSinceLastMention(topic: try c.decode(String.self, forKey: .topic),
                                         atMost: try c.decodeIfPresent(Int.self, forKey: .days) ?? 7)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "predicado observable desconocido: \(kind)")
        }
    }
}

/// Entorno de tests: valores fijos, cero dependencias del sistema.
public struct MockObservableEnvironment: ObservableEnvironment {
    public var workouts: Int
    public var overdue: Int
    public var sleep: Double?
    public var slots: [DateInterval]
    public var mentions: [String: Int]

    public init(workouts: Int = 0, overdue: Int = 0, sleep: Double? = nil,
                slots: [DateInterval] = [], mentions: [String: Int] = [:]) {
        self.workouts = workouts
        self.overdue = overdue
        self.sleep = sleep
        self.slots = slots
        self.mentions = mentions
    }

    public func workoutsThisWeek() async -> Int { workouts }
    public func overdueReminderCount() async -> Int { overdue }
    public func averageSleepHours(lastDays: Int) async -> Double? { sleep }
    public func freeSlots(minMinutes: Int, withinDays: Int) async -> [DateInterval] { slots }
    public func daysSinceLastMention(topic: String) async -> Int? { mentions[topic] }
}
