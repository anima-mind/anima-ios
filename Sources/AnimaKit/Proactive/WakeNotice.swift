// WakeNotice.swift — "cuando termine el sueño o en la mañana, un push" (campo
// batch 8 #7). Al completar un ciclo de consolidación se programa UNA
// notificación local para max(ahora, 7:30 si el ciclo corrió de noche), con el
// nombre del self como título y un cuerpo corto en su voz armado con el
// CycleReport — plantillas deterministas, sin LLM. Nunca más de una por día.
// Tap → el Mind sheet.

import Foundation

public enum WakeNotice {
    public static let category = "anima.wake"
    public static let prefix = "anima-wake-"
    /// Hora de entrega si el ciclo corrió de noche.
    public static let morning = (hour: 7, minute: 30)
    /// Desde esta hora un ciclo se considera "de noche" (entrega a la mañana siguiente).
    public static let nightStartsAt = 21

    public static let quietBody = "Dormí bien; ayer no dejó nada nuevo que guardar."

    /// Cuándo avisar: un ciclo nocturno (21:00–7:30) espera a las 7:30; de día, ya.
    public static func fireDate(completedAt now: Date, calendar: Calendar) -> Date {
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let beforeMorning = hour < morning.hour || (hour == morning.hour && minute < morning.minute)
        guard beforeMorning || hour >= nightStartsAt else { return now }
        let base = beforeMorning ? now : (calendar.date(byAdding: .day, value: 1, to: now) ?? now)
        return calendar.date(bySettingHour: morning.hour, minute: morning.minute, second: 0, of: base) ?? now
    }

    /// "Buenos días" / "Buenas tardes" / "Buenas noches" según la hora de entrega.
    public static func greeting(at date: Date, calendar: Calendar) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: return "Buenos días"
        case 12..<19: return "Buenas tardes"
        default: return "Buenas noches"
        }
    }

    /// El cuerpo, en su voz. Variantes por plantilla según la noche (deterministas).
    public static func body(_ report: Consolidator.CycleReport, night: Int, at date: Date,
                            calendar: Calendar) -> String {
        let hello = greeting(at: date, calendar: calendar)
        var parts: [String] = []
        if report.added > 0 { parts.append(report.added == 1 ? "1 recuerdo nuevo" : "\(report.added) recuerdos nuevos") }
        let refined = report.updated + report.reconsolidated
        if refined > 0 { parts.append(refined == 1 ? "1 recuerdo afinado" : "\(refined) recuerdos afinados") }
        if report.invalidated > 0 {
            parts.append(report.invalidated == 1 ? "1 recuerdo corregido" : "\(report.invalidated) recuerdos corregidos")
        }
        if report.goalsUpdated > 0 {
            parts.append(report.goalsUpdated == 1 ? "1 meta al día" : "\(report.goalsUpdated) metas al día")
        }
        guard !parts.isEmpty else { return "\(hello). \(quietBody)" }
        let listing = join(parts)
        let templates = [
            "\(hello). Dormí y ordené lo de ayer: \(listing). Noche #\(night).",
            "\(hello). Ya desperté: consolidé lo de ayer — \(listing). Noche #\(night).",
            "\(hello). Mientras dormías ordené lo de ayer: \(listing). Noche #\(night).",
        ]
        return templates[abs(night) % templates.count]
    }

    static func join(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " y " + (parts.last ?? "")
    }

    /// Id estable por día de entrega (idempotente: re-programar el mismo día lo reemplaza).
    public static func id(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return prefix + String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// "Avisarme cuando despierte" (Ajustes → Notificaciones), default ON, y el
/// día del último aviso (nunca más de uno por día).
public final class WakePreference: @unchecked Sendable {
    public static let key = "anima.wake.enabled"
    public static let lastDayKey = "anima.wake.lastDay"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.key) }
    }

    public var lastNotifiedId: String? {
        get { defaults.string(forKey: Self.lastDayKey) }
        set { defaults.set(newValue, forKey: Self.lastDayKey) }
    }
}

/// Programa el aviso de despertar al completar un ciclo.
public actor WakeNotifier {
    private let scheduler: LocalNotificationScheduler
    private let general: ProactivePreference?
    private let preference: WakePreference
    private let selfName: @Sendable () async -> String
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(scheduler: LocalNotificationScheduler, general: ProactivePreference?, preference: WakePreference,
                selfName: @escaping @Sendable () async -> String = { "Anima" }, calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.scheduler = scheduler
        self.general = general
        self.preference = preference
        self.selfName = selfName
        self.calendar = calendar
        self.now = now
    }

    /// nil si no corresponde (ciclo incompleto, avisos apagados, sin permiso o
    /// ya hubo aviso ese día).
    @discardableResult
    public func cycleCompleted(_ report: Consolidator.CycleReport, night: Int) async -> LocalNotificationRequest? {
        guard report.completed, preference.isEnabled, general?.isEnabled ?? true else { return nil }
        guard await scheduler.authorizationStatus() == .granted else { return nil }
        let fire = WakeNotice.fireDate(completedAt: now(), calendar: calendar)
        let id = WakeNotice.id(for: fire, calendar: calendar)
        guard preference.lastNotifiedId != id else { return nil }
        let request = LocalNotificationRequest(
            id: id, title: await selfName(),
            body: WakeNotice.body(report, night: night, at: fire, calendar: calendar),
            trigger: fire > now() ? .at(fire) : .immediate,
            categoryId: WakeNotice.category, deepLink: AnimaDeepLink.mind.url)
        await scheduler.schedule(request)
        preference.lastNotifiedId = id
        return request
    }

    /// Toggle apagado (general o el de despertar): lo pendiente se cancela.
    public func cancelPending() async {
        let pending = await scheduler.pendingIds().filter { $0.hasPrefix(WakeNotice.prefix) }
        if !pending.isEmpty { await scheduler.cancel(ids: pending) }
    }
}
