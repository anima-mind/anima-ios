// ProactiveReconciler.swift — lo que pasó mientras la app no miraba. Al abrir,
// al volver a foreground y en el pulso en background: cada recordatorio vencido
// se marca entregado y entra al chat como mensaje proactivo de Anima (turno
// assistant persistido: el modelo lo ve en el contexto del próximo turno).
// Idempotente: markFired saca al recordatorio de dueNow.

import Foundation

/// Mensaje proactivo de Anima para pintar en el chat (ya persistido).
public struct ProactiveMessage: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case reminder(id: String)
        case checkIn(goalId: String)
        case intention(id: String)

        /// "reminder" | "checkin" | "intention" (accessibility id y tag persistido).
        public var slug: String {
            switch self {
            case .reminder: return "reminder"
            case .checkIn: return "checkin"
            case .intention: return "intention"
            }
        }

        public var ref: String {
            switch self {
            case .reminder(let id), .checkIn(let id), .intention(let id): return id
            }
        }

        public init?(slug: String, ref: String) {
            switch slug {
            case "reminder": self = .reminder(id: ref)
            case "checkin": self = .checkIn(goalId: ref)
            case "intention": self = .intention(id: ref)
            default: return nil
            }
        }
    }

    public var kind: Kind
    public var text: String
    /// La hora del aviso (recordatorio) o de la pregunta (check-in, propuesta).
    public var at: Date?
    /// La meta del check-in, o a la que sirve el recordatorio.
    public var goalStatement: String?

    public init(kind: Kind, text: String, at: Date? = nil, goalStatement: String? = nil) {
        self.kind = kind
        self.text = text
        self.at = at
        self.goalStatement = goalStatement
    }

    /// Lo que viaja con el turno persistido: tras relanzar, el chat vuelve a
    /// pintar la card (no un texto plano).
    public var tag: ProactiveTag {
        ProactiveTag(kind: kind.slug, ref: kind.ref, at: at?.timeIntervalSince1970, goal: goalStatement)
    }

    public init?(tag: ProactiveTag, text: String) {
        guard let kind = Kind(slug: tag.kind, ref: tag.ref) else { return nil }
        self.init(kind: kind, text: text, at: tag.at.map(Date.init(timeIntervalSince1970:)), goalStatement: tag.goal)
    }
}

/// Marca proactiva de un turno del transcript (`turn_event.proactive_json`).
public struct ProactiveTag: Codable, Sendable, Equatable {
    public var kind: String
    public var ref: String
    public var at: Double?
    public var goal: String?

    public init(kind: String, ref: String, at: Double? = nil, goal: String? = nil) {
        self.kind = kind
        self.ref = ref
        self.at = at
        self.goal = goal
    }
}

public actor ProactiveReconciler {
    private let reminders: AnimaReminderStore
    private let otherModel: OtherModel?
    private let store: SymbolicStore?
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(reminders: AnimaReminderStore, otherModel: OtherModel? = nil, store: SymbolicStore? = nil,
                calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.reminders = reminders
        self.otherModel = otherModel
        self.store = store
        self.calendar = calendar
        self.now = now
    }

    /// Vencidos → entregados → mensajes en su voz en la sesión dada.
    @discardableResult
    public func reconcileDueReminders(sessionId: SessionID?) async -> [ProactiveMessage] {
        var out: [ProactiveMessage] = []
        for due in await reminders.dueNow() {
            guard await reminders.markFired(id: due.id) != nil else { continue }
            var goal: Goal?
            if let goalId = due.goalId { goal = await otherModel?.goal(id: goalId) }
            let message = ProactiveMessage(kind: .reminder(id: due.id), text: due.spokenMessage, at: due.fireAt,
                                           goalStatement: goal?.statement)
            persist(message, sessionId: sessionId)
            out.append(message)
        }
        return out
    }

    /// Al abrir el check-in de una meta (tap en la notificación): la pregunta de
    /// Anima en el chat. nil si la meta ya no motiva o el dueño ya respondió hoy
    /// (p.ej. desde la acción de la notificación): no se duplica.
    public func checkInPrompt(goalId: String, sessionId: SessionID?) async -> ProactiveMessage? {
        guard let otherModel, let goal = await otherModel.goal(id: goalId), goal.motivates,
              !(await otherModel.answeredToday(goalId: goalId)) else { return nil }
        let text = CheckInScheduler.chatPrompt(for: goal)
        if let open = await otherModel.lastCheckIn(goalId: goalId), open.answeredAt == nil,
           calendar.isDate(open.askedAt, inSameDayAs: now()) {
            return ProactiveMessage(kind: .checkIn(goalId: goalId), text: text, at: open.askedAt,
                                    goalStatement: goal.statement)
        }
        await otherModel.markCheckInAsked(goalId: goalId)
        let message = ProactiveMessage(kind: .checkIn(goalId: goalId), text: text, at: now(),
                                       goalStatement: goal.statement)
        persist(message, sessionId: sessionId)
        return message
    }

    /// Turno assistant con su marca proactiva (el modelo ve el texto; el chat, la card).
    func persist(_ message: ProactiveMessage, sessionId: SessionID?) {
        guard let store, let sessionId else { return }
        try? store.append(sessionId: sessionId, message: .assistant([.text(message.text)]), proactive: message.tag)
    }
}
