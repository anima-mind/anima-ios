// ProactiveScheduler.swift — sincroniza lo que Anima tiene que decir con las
// notificaciones locales pendientes. Idempotente: calcula el conjunto deseado
// (recordatorios, check-ins), lo trunca al tope de iOS (60 más próximas; el
// resto entra en la próxima sincronización) y aplica el diff. Los textos se
// fijan aquí, al programar: al disparar no corre ningún LLM.

import Foundation

public actor ProactiveScheduler {
    private let scheduler: LocalNotificationScheduler
    private let reminders: AnimaReminderStore
    private let otherModel: OtherModel?
    private let selfName: @Sendable () async -> String
    private let calendar: Calendar
    private let maxPending: Int
    /// Ocurrencias que se programan por recordatorio que se repite.
    private let occurrencesPerReminder: Int
    private let preference: ProactivePreference?

    public init(scheduler: LocalNotificationScheduler,
                reminders: AnimaReminderStore,
                otherModel: OtherModel? = nil,
                selfName: @escaping @Sendable () async -> String = { "Anima" },
                calendar: Calendar = .current,
                maxPending: Int = ProactiveNotificationIDs.maxPending,
                occurrencesPerReminder: Int = 7,
                preference: ProactivePreference? = nil) {
        self.scheduler = scheduler
        self.reminders = reminders
        self.otherModel = otherModel
        self.selfName = selfName
        self.calendar = calendar
        self.maxPending = maxPending
        self.occurrencesPerReminder = occurrencesPerReminder
        self.preference = preference
    }

    private var isEnabled: Bool { preference?.isEnabled ?? true }

    // MARK: - Conjunto deseado

    /// Check-ins primero (repetitivos, pocos y sin re-sync), luego los
    /// recordatorios por fecha. Truncado a `maxPending`.
    public func desiredRequests() async -> [LocalNotificationRequest] {
        let title = await selfName()
        var out: [LocalNotificationRequest] = []
        if let otherModel {
            for goal in await otherModel.desire() {
                out += CheckInScheduler.requests(for: goal, title: title)
            }
        }
        var timed: [(Date, LocalNotificationRequest)] = []
        for reminder in await reminders.list(.upcoming, limit: maxPending) {
            let dates = AnimaReminderStore.occurrences(of: reminder, count: occurrencesPerReminder, calendar: calendar)
            for (index, date) in dates.enumerated() {
                timed.append((date, Self.reminderRequest(reminder, title: title, at: date, occurrence: index)))
            }
        }
        out += timed.sorted { $0.0 < $1.0 }.map(\.1)
        return Array(out.prefix(maxPending))
    }

    // MARK: - Sincronización

    /// Aplica el diff contra los pendientes de Anima (no toca handoff ni
    /// aprobaciones). Pide permiso la primera vez que hay algo que programar.
    /// Devuelve los ids programados.
    @discardableResult
    public func sync() async -> [String] {
        guard isEnabled else {
            let managed = await scheduler.pendingIds().filter(Self.isManaged)
            if !managed.isEmpty { await scheduler.cancel(ids: managed) }
            return []
        }
        let desired = await desiredRequests()
        if !desired.isEmpty, await scheduler.authorizationStatus() == .notDetermined {
            _ = await scheduler.requestAuthorization()
        }
        let desiredIds = Set(desired.map(\.id))
        let stale = await scheduler.pendingIds().filter { id in
            Self.isManaged(id) && !desiredIds.contains(id)
        }
        if !stale.isEmpty { await scheduler.cancel(ids: stale) }
        for request in desired { await scheduler.schedule(request) }
        return desired.map(\.id)
    }

    /// Una Intention del pulso en background → notificación inmediata.
    public func notify(_ intention: Intention) async {
        guard isEnabled else { return }
        if await scheduler.authorizationStatus() == .notDetermined {
            _ = await scheduler.requestAuthorization()
        }
        let request = LocalNotificationRequest(
            id: ProactiveNotificationIDs.intentionPrefix + intention.id,
            title: await selfName(), body: intention.proposedText, trigger: .immediate,
            categoryId: ProactiveNotificationIDs.intentionCategory,
            deepLink: AnimaDeepLink.intention(id: intention.id).url)
        await scheduler.schedule(request)
    }

    // MARK: - Builders

    static func isManaged(_ id: String) -> Bool {
        id.hasPrefix(ProactiveNotificationIDs.reminderPrefix) || id.hasPrefix(ProactiveNotificationIDs.checkInPrefix)
    }

    /// id `anima-reminder-<id>` (+ `-<n>` en las ocurrencias siguientes de uno que se repite).
    static func reminderRequest(_ reminder: AnimaReminder, title: String, at date: Date,
                                occurrence: Int) -> LocalNotificationRequest {
        let suffix = occurrence == 0 ? "" : "-\(occurrence)"
        return LocalNotificationRequest(
            id: ProactiveNotificationIDs.reminderPrefix + reminder.id + suffix,
            title: title, body: reminder.spokenMessage, trigger: .at(date),
            categoryId: ProactiveNotificationIDs.reminderCategory,
            deepLink: AnimaDeepLink.reminder(id: reminder.id).url)
    }
}
