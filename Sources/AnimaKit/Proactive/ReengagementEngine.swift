// ReengagementEngine.swift — el estado de los avisos por inactividad: último uso,
// la cadena programada (qué pregunta lleva cada aviso) y lo ya entregado. La
// lógica de CUÁNDO es del planner (puro); aquí se le asignan las preguntas
// (las del sueño primero, luego las de respaldo rotando) y se arman los requests.

import Foundation
import GRDB

public actor ReengagementEngine {
    private let preference: ReengagementPreference
    private let questions: ReengagementQuestionStore?
    private let planner: ReengagementPlanner
    /// Pulsos del deseo ya entregados HOY (comparten el tope diario).
    private let pulsesToday: @Sendable () async -> Int
    /// El aviso de despertar (7:30) también cuenta para la distancia y el tope.
    private let wake: WakePreference?
    private let now: @Sendable () -> Date
    /// Cuánto tiempo un aviso entregado sin respuesta aparece al abrir la app.
    public static let showOnOpenWindow: TimeInterval = 12 * 3600

    public init(preference: ReengagementPreference, questions: ReengagementQuestionStore?,
                planner: ReengagementPlanner = ReengagementPlanner(),
                pulsesToday: @escaping @Sendable () async -> Int = { 0 },
                wake: WakePreference? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.wake = wake
        self.preference = preference
        self.questions = questions
        self.planner = planner
        self.pulsesToday = pulsesToday
        self.now = now
    }

    /// Pulsos del deseo de hoy (hora local) en `desire_pulse`.
    public static func pulseCounter(queue: DatabaseQueue, calendar: Calendar = .autoupdatingCurrent,
                                    now: @escaping @Sendable () -> Date = { Date() }) -> @Sendable () async -> Int {
        {
            let start = calendar.startOfDay(for: now())
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            return (try? queue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM desire_pulse WHERE ts >= ? AND ts < ?",
                                 arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970])
            }).flatMap { $0 } ?? 0
        }
    }

    // MARK: - Uso

    /// Un turno del dueño (o el tap a un aviso): la cadena arranca de nuevo desde
    /// aquí y el back-off vuelve a N.
    public func recordUse(at date: Date? = nil) {
        reconcileDelivered()
        preference.lastUseAt = date ?? now()
    }

    public var lastUseAt: Date? { preference.lastUseAt }

    public var isEnabled: Bool { preference.isEnabled }

    /// El aviso de despertar que el sueño programa casi cada noche (7:30): el
    /// planner lo trata como un aviso más de Anima ese día.
    static let predictedWake: LocalNotificationRequest = {
        var c = DateComponents()
        c.hour = WakeNotice.morning.hour
        c.minute = WakeNotice.morning.minute
        return LocalNotificationRequest(id: WakeNotice.prefix + "predicted", title: "", body: "",
                                        trigger: .calendar(c, repeats: true), categoryId: WakeNotice.category,
                                        deepLink: nil)
    }()

    // MARK: - La cadena

    /// Los requests de la cadena (vacío si está apagado). `others`: lo demás que
    /// Anima tiene programado (check-ins, recordatorios) — el planner lo esquiva.
    /// `limit`: los cupos de iOS que quedan. El plan guarda SOLO lo que de verdad
    /// se programa: lo que no cupo jamás cuenta como entregado.
    public func requests(others: [LocalNotificationRequest], title: String,
                         limit: Int = .max) async -> [LocalNotificationRequest] {
        reconcileDelivered()
        guard preference.isEnabled, limit > 0 else {
            preference.plan = []
            return []
        }
        let others = (wake?.isEnabled ?? false) ? others + [Self.predictedWake] : others
        let current = now()
        let lastUse = preference.lastUseAt ?? current
        if preference.lastUseAt == nil { preference.lastUseAt = current }
        let today = await pulsesToday()
        let calendar = planner.calendar
        let fires = planner.chain(lastUse: lastUse, days: preference.days, others: others, now: current,
                                  load: { calendar.isDate($0, inSameDayAs: current) ? today : 0 }).prefix(limit)
        let picked = pick(count: fires.count)
        let plan = zip(fires, picked).map { ReengagementPlanEntry(fireAt: $0, ref: $1.ref, text: $1.text) }
        preference.plan = plan
        return plan.enumerated().map { index, entry in
            Self.request(id: ReengagementIDs.prefix + String(index), title: title, entry: entry, trigger: .at(entry.fireAt))
        }
    }

    /// Sin permiso (o sin cupo): nada está programado, así que nada se entregará.
    public func clearPlan() {
        preference.plan = []
    }

    /// "Probar en 1 minuto": un aviso suelto con la mejor pregunta disponible (la
    /// del sueño, para ver la real). Queda reservada: la cadena, al re-planearse,
    /// ya no la lleva (ni la duplica ni la quema). Se recuerda hasta que suene.
    public func probeRequest(after seconds: TimeInterval, title: String) -> LocalNotificationRequest {
        reconcileDelivered()
        let entry = pick(count: 1, includingProbe: true).first
            ?? (ref: ReengagementFallback.ref(0), text: ReengagementFallback.questions[0])
        let fire = now().addingTimeInterval(seconds)
        let probe = ReengagementPlanEntry(fireAt: fire, ref: entry.ref, text: entry.text)
        preference.probe = probe
        return Self.request(id: ReengagementIDs.probeId, title: title, entry: probe, trigger: .at(fire))
    }

    /// El probe pendiente se cancela (toggle apagado): su pregunta vuelve a estar libre.
    public func cancelProbe() {
        preference.probe = nil
    }

    static func request(id: String, title: String, entry: ReengagementPlanEntry,
                        trigger: LocalNotificationRequest.Trigger) -> LocalNotificationRequest {
        LocalNotificationRequest(id: id, title: title, body: entry.text, trigger: trigger,
                                 categoryId: ReengagementIDs.category,
                                 deepLink: AnimaDeepLink.nudge(id: entry.ref).url)
    }

    /// Las preguntas del sueño primero; si no alcanzan, las de respaldo en rotación
    /// sin repetir las últimas entregadas.
    private func pick(count: Int, includingProbe: Bool = false) -> [(ref: String, text: String)] {
        guard count > 0 else { return [] }
        // La pregunta del probe pendiente no va también en la cadena.
        let reserved = includingProbe ? nil : preference.probe?.ref
        var out: [(ref: String, text: String)] = (questions?.upcoming(limit: count + 1) ?? [])
            .filter { $0.id != reserved }.prefix(count).map { ($0.id, $0.text) }
        let recent = Set(preference.delivered.suffix(3).map { ReengagementTextGuard.key($0.text) })
        let pool = ReengagementFallback.questions
        var cursor = preference.fallbackCursor
        var tries = 0
        while out.count < count, tries < pool.count * 2 {
            let index = ((cursor % pool.count) + pool.count) % pool.count
            cursor += 1
            tries += 1
            if recent.contains(ReengagementTextGuard.key(pool[index])) && tries <= pool.count { continue }
            if ReengagementFallback.ref(index) == reserved { continue }
            out.append((ReengagementFallback.ref(index), pool[index]))
        }
        return out
    }

    // MARK: - Entregados

    /// Los avisos cuya hora ya pasó: la pregunta queda usada (no se repite) y
    /// pasa a la lista de entregados. Idempotente.
    @discardableResult
    public func reconcileDelivered() -> [ReengagementDelivery] {
        let current = now()
        var fresh: [ReengagementDelivery] = []
        if let probe = preference.probe, probe.fireAt <= current {
            preference.probe = nil
            fresh.append(deliver(ref: probe.ref, text: probe.text, at: probe.fireAt))
        }
        let plan = preference.plan
        let due = plan.filter { $0.fireAt <= current }
        guard !due.isEmpty else { return fresh }
        fresh += due.map { deliver(ref: $0.ref, text: $0.text, at: $0.fireAt) }
        preference.plan = plan.filter { $0.fireAt > current }
        return fresh
    }

    private func deliver(ref: String, text: String, at date: Date) -> ReengagementDelivery {
        if let index = ReengagementFallback.index(of: ref) {
            preference.fallbackCursor = index + 1
        } else {
            questions?.markDelivered(id: ref, at: date)
        }
        var delivered = preference.delivered
        if let existing = delivered.last(where: { $0.ref == ref && abs($0.at.timeIntervalSince(date)) < 60 }) {
            return existing
        }
        let item = ReengagementDelivery(ref: ref, text: text, at: date)
        delivered.append(item)
        preference.delivered = delivered
        return item
    }

    /// Tap al aviso: el texto de la pregunta (entregada, en la cadena, en la base
    /// o de respaldo), marcada entregada y vista; el tap cuenta como uso. nil si
    /// la referencia no resuelve a nada.
    public func open(ref: String) -> (delivery: ReengagementDelivery, alreadyShown: Bool)? {
        reconcileDelivered()
        let current = now()
        var item: ReengagementDelivery
        // Las de respaldo rotan: solo cuenta la entrega reciente de esa referencia.
        let horizon = current.addingTimeInterval(-TimeInterval(planner.maxGapDays + 1) * 86_400)
        if let known = preference.delivered.last(where: { $0.ref == ref && $0.at > horizon }) {
            item = known
        } else if let text = preference.plan.first(where: { $0.ref == ref })?.text
                    ?? (preference.probe?.ref == ref ? preference.probe?.text : nil)
                    ?? questions?.question(id: ref)?.text ?? ReengagementFallback.text(for: ref) {
            item = deliver(ref: ref, text: text, at: current)
        } else {
            return nil
        }
        let alreadyShown = item.shown
        item.shown = true
        markShown(item)
        preference.lastUseAt = current
        return (item, alreadyShown)
    }

    /// Al abrir la app sin tocar el aviso: los entregados en las últimas 12 h que
    /// el dueño aún no vio ni respondió (sin uso desde entonces). Quedan vistos.
    public func unseenRecent() -> [ReengagementDelivery] {
        reconcileDelivered()
        let current = now()
        let lastUse = preference.lastUseAt ?? .distantPast
        let pending = preference.delivered.filter {
            !$0.shown && $0.at > lastUse && current.timeIntervalSince($0.at) <= Self.showOnOpenWindow
        }
        for item in pending {
            var seen = item
            seen.shown = true
            markShown(seen)
        }
        return pending
    }

    private func markShown(_ item: ReengagementDelivery) {
        var delivered = preference.delivered
        if let index = delivered.lastIndex(where: { $0.ref == item.ref && $0.at == item.at }) {
            delivered[index] = item
        } else {
            delivered.append(item)
        }
        preference.delivered = delivered
    }
}
