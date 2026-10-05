// Observables.swift — predicados observables tipados (§5.8). Decisión fijada:
// ObservablePredicate es un enum CERRADO, no strings evaluados por el modelo —
// el deseo crece con el cuerpo (release), no con el prompt. Cada caso se evalúa
// BARATO y local (0 LLM) contra un ObservableEnvironment: en producción los
// providers reales (EventKit/HealthKit vía las tools de Fase 1), en tests un mock.

import Foundation
import GRDB

/// La superficie que un predicado consulta para saber si la realidad avanza hacia
/// la meta. Todo local y barato; ninguna llamada a LLM. En producción lo implementa
/// SystemObservableEnvironment (EventKit); en tests, MockObservableEnvironment.
public protocol ObservableEnvironment: Sendable {
    func workoutsThisWeek() async -> Int
    func overdueReminderCount() async -> Int
    func averageSleepHours(lastDays: Int) async -> Double?
    func freeSlots(minMinutes: Int, withinDays: Int) async -> [DateInterval]
    func daysSinceLastMention(topic: String) async -> Int?
    /// Días desde el último check-in con avance (yes/partial) de la meta; nil = nunca.
    func daysSinceProgress(goalId: String) async -> Int?
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
    /// El dueño reporta avance (check-in yes/partial) al menos cada `everyDays`.
    case progressCheckIn(everyDays: Int)

    public var label: String {
        switch self {
        case .workoutsPerWeek(let n): return "entrenar al menos \(n)x por semana"
        case .remindersOverdue(let n): return "no más de \(n) recordatorios vencidos"
        case .sleepHours(let h, let d): return "dormir al menos \(h)h (últimos \(d) días)"
        case .calendarFreeSlot(let m, let d): return "reservar un hueco de \(m)min en \(d) días"
        case .daysSinceLastMention(let t, let n): return "retomar '\(t)' cada \(n) días"
        case .progressCheckIn(let n): return "reportar avance al menos cada \(n) días"
        }
    }

    /// Evaluación local (0 LLM): la corre el DesireEngine antes de gastar un pulso.
    /// `goalId` solo lo usan los predicados sobre la propia meta (progress_check_in).
    public func evaluate(in env: ObservableEnvironment, goalId: String? = nil) async -> ObservableReading {
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
            // Sin dato no hay gap falso (como el sueño): una meta nueva no es una brecha.
            guard let days = await env.daysSinceLastMention(topic: t) else {
                return ObservableReading(satisfied: true, detail: "sin datos de menciones de '\(t)'")
            }
            return ObservableReading(satisfied: days <= n, detail: "\(days) días desde '\(t)' (máximo \(n))")
        case .progressCheckIn(let n):
            guard let goalId, let days = await env.daysSinceProgress(goalId: goalId) else {
                return ObservableReading(satisfied: false, detail: "sin check-ins con avance todavía")
            }
            return ObservableReading(satisfied: days < n, detail: "último avance hace \(days) días (cada \(n))")
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
        case everyDays = "every_days"
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
        case .progressCheckIn(let n):
            try c.encode("progress_check_in", forKey: .kind)
            try c.encode(n, forKey: .everyDays)
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
        case "progress_check_in":
            self = .progressCheckIn(everyDays: try c.decodeIfPresent(Int.self, forKey: .everyDays) ?? 7)
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
    public var progress: [String: Int]

    public init(workouts: Int = 0, overdue: Int = 0, sleep: Double? = nil,
                slots: [DateInterval] = [], mentions: [String: Int] = [:], progress: [String: Int] = [:]) {
        self.workouts = workouts
        self.overdue = overdue
        self.sleep = sleep
        self.slots = slots
        self.mentions = mentions
        self.progress = progress
    }

    public func workoutsThisWeek() async -> Int { workouts }
    public func overdueReminderCount() async -> Int { overdue }
    public func averageSleepHours(lastDays: Int) async -> Double? { sleep }
    public func freeSlots(minMinutes: Int, withinDays: Int) async -> [DateInterval] { slots }
    public func daysSinceLastMention(topic: String) async -> Int? { mentions[topic] }
    public func daysSinceProgress(goalId: String) async -> Int? { progress[goalId] }
}

/// "Días desde la última mención" (§5.8) sobre el transcript: el turno del dueño
/// más reciente cuyo texto contiene el topic (LIKE, sin mayúsculas para ASCII).
public struct MentionIndex: Sendable {
    private let queue: DatabaseQueue
    private let now: @Sendable () -> Date

    public init(queue: DatabaseQueue, now: @escaping @Sendable () -> Date = { Date() }) {
        self.queue = queue
        self.now = now
    }

    public func daysSinceLastMention(topic: String) -> Int? {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let escaped = trimmed.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let last = (try? queue.read { db in
            try Double.fetchOne(db, sql: """
                SELECT created_at FROM turn_event
                WHERE role='user' AND content_json LIKE ? ESCAPE '\\'
                ORDER BY created_at DESC LIMIT 1
                """, arguments: ["%\(escaped)%"])
        }).flatMap { $0 }
        return last.map { max(0, Int(now().timeIntervalSince1970 - $0) / 86_400) }
    }
}
