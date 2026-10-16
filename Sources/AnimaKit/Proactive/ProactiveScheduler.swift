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
    /// Avisos por inactividad: la cadena se suma al conjunto deseado.
    private let reengagement: ReengagementEngine?
    /// Tras cada sincronización (= tras cada cambio de recordatorios/metas): la
    /// app republica el snapshot de los widgets aquí.
    private var afterSync: (@Sendable () async -> Void)?

    public init(scheduler: LocalNotificationScheduler,
                reminders: AnimaReminderStore,
                otherModel: OtherModel? = nil,
                selfName: @escaping @Sendable () async -> String = { "Anima" },
                calendar: Calendar = .current,
                maxPending: Int = ProactiveNotificationIDs.maxPending,
                occurrencesPerReminder: Int = 7,
                preference: ProactivePreference? = nil,
                reengagement: ReengagementEngine? = nil) {
        self.scheduler = scheduler
        self.reminders = reminders
        self.otherModel = otherModel
        self.selfName = selfName
        self.calendar = calendar
        self.maxPending = maxPending
        self.occurrencesPerReminder = occurrencesPerReminder
        self.preference = preference
        self.reengagement = reengagement
    }

    private var isEnabled: Bool { preference?.isEnabled ?? true }

    public func setAfterSync(_ hook: (@Sendable () async -> Void)?) {
        afterSync = hook
    }

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
        let ids = await syncNotifications()
        await afterSync?()
        return ids
    }

    private func syncNotifications() async -> [String] {
        guard isEnabled else {
            let managed = await scheduler.pendingIds().filter {
                Self.isManaged($0) || $0.hasPrefix(WakeNotice.prefix) || $0.hasPrefix(ReengagementIDs.prefix)
            }
            if !managed.isEmpty { await scheduler.cancel(ids: managed) }
            await reengagement?.clearPlan()
            await reengagement?.cancelProbe()
            return []
        }
        let base = await desiredRequests()
        // Los avisos por inactividad jamás piden el permiso: solo se programan si
        // el dueño ya lo dio (el permiso se pide cuando hay algo que él pidió).
        if !base.isEmpty, await scheduler.authorizationStatus() == .notDetermined {
            _ = await scheduler.requestAuthorization()
        }
        let desired = base + (await nudgeRequests(others: base))
        await cancelProbeIfOff()
        let desiredIds = Set(desired.map(\.id))
        let stale = await scheduler.pendingIds().filter { id in
            Self.isManaged(id) && !desiredIds.contains(id)
        }
        if !stale.isEmpty { await scheduler.cancel(ids: stale) }
        for request in desired { await scheduler.schedule(request) }
        return desired.map(\.id)
    }

    // MARK: - Avisos por inactividad

    /// La cadena (vacía sin permiso concedido o con el aviso apagado).
    private func nudgeRequests(others: [LocalNotificationRequest]) async -> [LocalNotificationRequest] {
        guard let reengagement else { return [] }
        // Sin permiso nada se entrega: el plan se vacía (jamás cards de avisos que no sonaron).
        guard await scheduler.authorizationStatus() == .granted else {
            await reengagement.clearPlan()
            return []
        }
        // Lo que el dueño pidió (recordatorios, check-ins) gana los cupos de iOS,
        // y el plan guarda solo lo que cupo.
        let room = max(0, maxPending - others.count)
        return await reengagement.requests(others: others, title: await selfName(), limit: room)
    }

    /// Toggle de los avisos apagado: el "Probar" pendiente también se cancela.
    private func cancelProbeIfOff() async {
        guard let reengagement, !(await reengagement.isEnabled) else { return }
        await reengagement.cancelProbe()
        if await scheduler.pendingIds().contains(ReengagementIDs.probeId) {
            await scheduler.cancel(ids: [ReengagementIDs.probeId])
        }
    }

    /// El dueño usó Anima (un turno de cualquier superficie, también en
    /// background): la cadena arranca de nuevo desde ahora. Solo toca los avisos
    /// por inactividad (no re-programa recordatorios ni republica widgets).
    public func ownerUsedAnima() async {
        guard let reengagement else { return }
        await reengagement.recordUse()
        await syncReengagement()
    }

    /// Re-programa solo la cadena de inactividad contra lo demás programado.
    @discardableResult
    public func syncReengagement() async -> [String] {
        guard reengagement != nil, isEnabled else { return [] }
        let nudges = await nudgeRequests(others: await desiredRequests())
        await cancelProbeIfOff()
        let ids = Set(nudges.map(\.id))
        let stale = await scheduler.pendingIds().filter { ReengagementIDs.isChain($0) && !ids.contains($0) }
        if !stale.isEmpty { await scheduler.cancel(ids: stale) }
        for request in nudges { await scheduler.schedule(request) }
        return nudges.map(\.id)
    }

    /// "Probar en 1 minuto" (Ajustes) y el modo UI-test: un aviso suelto con la
    /// próxima pregunta. Lo pidió el dueño, así que aquí sí puede pedir permiso.
    @discardableResult
    public func scheduleProbeNudge(after seconds: TimeInterval) async -> LocalNotificationRequest? {
        guard let reengagement, isEnabled else { return nil }
        if await scheduler.authorizationStatus() == .notDetermined {
            _ = await scheduler.requestAuthorization()
        }
        guard await scheduler.authorizationStatus() == .granted else { return nil }
        let request = await reengagement.probeRequest(after: seconds, title: await selfName())
        await scheduler.schedule(request)
        // La cadena suelta la pregunta que ahora lleva el probe.
        await syncReengagement()
        return request
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
            || ReengagementIDs.isChain(id)
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
