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
        /// Aviso por inactividad: la pregunta de Anima (ref = id de la pregunta).
        case nudge(id: String)

        /// "reminder" | "checkin" | "intention" | "nudge" (accessibility id y tag
        /// persistido; un build viejo no reconoce "nudge" y lo pinta como texto).
        public var slug: String {
            switch self {
            case .reminder: return "reminder"
            case .checkIn: return "checkin"
            case .intention: return "intention"
            case .nudge: return "nudge"
            }
        }

        public var ref: String {
            switch self {
            case .reminder(let id), .checkIn(let id), .intention(let id), .nudge(let id): return id
            }
        }

        public init?(slug: String, ref: String) {
            switch slug {
            case "reminder": self = .reminder(id: ref)
            case "checkin": self = .checkIn(goalId: ref)
            case "intention": self = .intention(id: ref)
            case "nudge": self = .nudge(id: ref)
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

/// Escribe en el transcript EN COLA con los turnos de la sesión (en la app:
/// `AgentLoop.appendAfterTurns`). Sin ella se escribe directo (tests, previews).
public typealias TranscriptGate = @Sendable (SessionID, @escaping @Sendable () -> Void) async -> Void

public actor ProactiveReconciler {
    private let reminders: AnimaReminderStore
    private let otherModel: OtherModel?
    private let store: SymbolicStore?
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let reengagement: ReengagementEngine?

    public init(reminders: AnimaReminderStore, otherModel: OtherModel? = nil, store: SymbolicStore? = nil,
                calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() },
                reengagement: ReengagementEngine? = nil) {
        self.reminders = reminders
        self.otherModel = otherModel
        self.store = store
        self.calendar = calendar
        self.now = now
        self.reengagement = reengagement
    }

    /// Lo que ella dice sin turno no se intercala con un turno en vuelo.
    private var transcriptGate: TranscriptGate?

    public func setTranscriptGate(_ gate: TranscriptGate?) {
        transcriptGate = gate
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
            await persist(message, sessionId: sessionId)
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
        await persist(message, sessionId: sessionId)
        return message
    }

    /// Tap a un aviso por inactividad: la pregunta entra al chat como mensaje de
    /// Anima (turno persistido: el modelo la ve y la respuesta sigue la charla).
    /// Un segundo tap no la duplica. nil si la referencia no resuelve.
    public func nudgePrompt(ref: String, sessionId: SessionID?) async -> ProactiveMessage? {
        guard let reengagement, let opened = await reengagement.open(ref: ref) else { return nil }
        let message = ProactiveMessage(kind: .nudge(id: ref), text: opened.delivery.text, at: opened.delivery.at)
        if !opened.alreadyShown { await persist(message, sessionId: sessionId) }
        return message
    }

    /// Al abrir la app sin tocar el aviso: los entregados hace poco y sin
    /// respuesta también quedan en el chat, listos para responder.
    public func reconcileNudges(sessionId: SessionID?) async -> [ProactiveMessage] {
        guard let reengagement else { return [] }
        var out: [ProactiveMessage] = []
        for item in await reengagement.unseenRecent() {
            let message = ProactiveMessage(kind: .nudge(id: item.ref), text: item.text, at: item.at)
            await persist(message, sessionId: sessionId)
            out.append(message)
        }
        return out
    }

    /// Turno assistant con su marca proactiva (el modelo ve el texto; el chat, la card).
    /// En cola con los turnos de la sesión (jamás entre un tool_use y su tool_result).
    func persist(_ message: ProactiveMessage, sessionId: SessionID?) async {
        guard let store, let sessionId else { return }
        let write: @Sendable () -> Void = {
            try? store.append(sessionId: sessionId, message: .assistant([.text(message.text)]), proactive: message.tag)
        }
        if let transcriptGate { await transcriptGate(sessionId, write) } else { write() }
    }
}
