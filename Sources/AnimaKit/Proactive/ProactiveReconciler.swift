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
    }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
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

    /// Vencidos → entregados → mensajes "Te recordé: …" en la sesión dada.
    @discardableResult
    public func reconcileDueReminders(sessionId: SessionID?) async -> [ProactiveMessage] {
        var out: [ProactiveMessage] = []
        for due in await reminders.dueNow() {
            guard await reminders.markFired(id: due.id) != nil else { continue }
            var goal: Goal?
            if let goalId = due.goalId { goal = await otherModel?.goal(id: goalId) }
            let text = Self.reminderText(due, goal: goal)
            persist(text, sessionId: sessionId)
            out.append(ProactiveMessage(kind: .reminder(id: due.id), text: text))
        }
        return out
    }

    /// Al abrir el check-in de una meta (tap en la notificación): la pregunta de
    /// Anima en el chat. nil si la meta ya no motiva o el dueño ya respondió hoy
    /// (p.ej. desde la acción de la notificación): no se duplica.
    public func checkInPrompt(goalId: String, sessionId: SessionID?) async -> ProactiveMessage? {
        guard let otherModel, let goal = await otherModel.goal(id: goalId), goal.motivates,
              !(await otherModel.answeredToday(goalId: goalId)) else { return nil }
        if let open = await otherModel.lastCheckIn(goalId: goalId), open.answeredAt == nil,
           calendar.isDate(open.askedAt, inSameDayAs: now()) {
            return ProactiveMessage(kind: .checkIn(goalId: goalId), text: CheckInScheduler.chatPrompt(for: goal))
        }
        await otherModel.markCheckInAsked(goalId: goalId)
        let text = CheckInScheduler.chatPrompt(for: goal)
        persist(text, sessionId: sessionId)
        return ProactiveMessage(kind: .checkIn(goalId: goalId), text: text)
    }

    static func reminderText(_ reminder: AnimaReminder, goal: Goal?) -> String {
        if let goal {
            return "Te recordé: \(reminder.text) (va por tu meta \"\(goal.statement)\"). ¿Cómo te fue?"
        }
        return "Te recordé: \(reminder.text). ¿Cómo te fue?"
    }

    func persist(_ text: String, sessionId: SessionID?) {
        guard let store, let sessionId else { return }
        try? store.append(sessionId: sessionId, message: .assistant([.text(text)]))
    }
}
