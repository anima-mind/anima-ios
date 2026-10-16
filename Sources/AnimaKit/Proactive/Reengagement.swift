// Reengagement.swift — "avisos si no hablamos": cuando el dueño lleva N días sin
// usar Anima (2, 3 o 5; default 3), UNA notificación local con una pregunta
// suya ("¿Cómo te fue en la reunión con Pedro?"). Cada turno (chat, voz, gafas,
// Siri) reprograma la cadena desde "último uso". Las preguntas las pre-genera el
// sueño (Consolidator); al disparar no corre ningún LLM: el texto ya está fijo.
//
// Anti-insistencia: la cadena es una función pura del último uso. Si el dueño
// no vuelve, los avisos se espacian N, N, 2N, 2N, 4N… (tope 14 días): cada dos
// ignorados seguidos el intervalo se duplica, y cualquier uso lo resetea. Ventana
// diurna 10:00–20:00 (nunca de noche), comparte el tope diario (≤4) con check-ins,
// recordatorios y el pulso del deseo, y nunca cae a <3 h de otro aviso de Anima.

import Foundation

public enum ReengagementIDs {
    public static let category = "anima.nudge"
    /// `anima-nudge-<n>`: la cadena programada (ids estables, n = 0…3).
    public static let prefix = "anima-nudge-"
    /// "Probar en 1 minuto" (Ajustes): un aviso suelto que la sincronización no toca.
    public static let probeId = "anima-nudge-probe"
    /// Lo que iOS muestra con las vistas previas ocultas (nunca la pregunta).
    public static let hiddenPreviewPlaceholder = "Quiero saber cómo estás"

    static func isChain(_ id: String) -> Bool { id.hasPrefix(prefix) && id != probeId }
}

/// "Probar en 1 minuto" (Ajustes → Notificaciones): para verlo en el teléfono
/// sin esperar días. Usa la próxima pregunta real y no toca la cadena.
public enum ReengagementProbe {
    public static let lead: TimeInterval = 60
}

/// "Avisos si no hablamos" (Ajustes → Notificaciones) y el estado de la cadena.
/// Mismo patrón que `WakePreference`: UserDefaults, default encendido cada 3 días.
public final class ReengagementPreference: @unchecked Sendable {
    public static let enabledKey = "anima.nudge.enabled"
    public static let daysKey = "anima.nudge.days"
    static let lastUseKey = "anima.nudge.lastUse"
    static let planKey = "anima.nudge.plan"
    static let probeKey = "anima.nudge.probe"
    static let deliveredKey = "anima.nudge.delivered"
    static let fallbackCursorKey = "anima.nudge.fallbackCursor"

    public static let dayOptions = [2, 3, 5]
    public static let defaultDays = 3
    /// Cuántos avisos entregados recuerda (para no repetir y para pintarlos al abrir).
    static let deliveredMemory = 12

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// 2, 3 o 5 (cualquier otro valor persistido cae al default).
    public var days: Int {
        get {
            let stored = defaults.integer(forKey: Self.daysKey)
            return Self.dayOptions.contains(stored) ? stored : Self.defaultDays
        }
        set { defaults.set(Self.dayOptions.contains(newValue) ? newValue : Self.defaultDays, forKey: Self.daysKey) }
    }

    public internal(set) var lastUseAt: Date? {
        get { (defaults.object(forKey: Self.lastUseKey) as? Double).map(Date.init(timeIntervalSince1970:)) }
        set { defaults.set(newValue?.timeIntervalSince1970, forKey: Self.lastUseKey) }
    }

    var plan: [ReengagementPlanEntry] {
        get { decode(Self.planKey) ?? [] }
        set { encode(newValue, Self.planKey) }
    }

    var delivered: [ReengagementDelivery] {
        get { decode(Self.deliveredKey) ?? [] }
        set { encode(Array(newValue.suffix(Self.deliveredMemory)), Self.deliveredKey) }
    }

    /// El "Probar en 1 minuto" pendiente (su pregunta no va en la cadena).
    var probe: ReengagementPlanEntry? {
        get { decode(Self.probeKey) }
        set {
            if let newValue { encode(newValue, Self.probeKey) } else { defaults.removeObject(forKey: Self.probeKey) }
        }
    }

    var fallbackCursor: Int {
        get { defaults.integer(forKey: Self.fallbackCursorKey) }
        set { defaults.set(newValue, forKey: Self.fallbackCursorKey) }
    }

    private func decode<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func encode<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

/// Un aviso de la cadena programada: cuándo y qué pregunta lleva.
struct ReengagementPlanEntry: Codable, Sendable, Equatable {
    var fireAt: Date
    /// id de `reengagement_question` o `fallback-<n>`.
    var ref: String
    var text: String
}

/// Un aviso que iOS ya entregó (la hora pasó) o que el dueño abrió.
public struct ReengagementDelivery: Codable, Sendable, Equatable {
    public var ref: String
    public var text: String
    public var at: Date
    /// Ya está en el chat como pregunta de Anima.
    public var shown: Bool = false
}

// MARK: - Planificador (puro, determinista)

/// Calcula la cadena de avisos a partir del último uso. Sin estado: la misma
/// entrada da la misma salida, así reprogramar (turno, apertura, pulso) es idempotente.
public struct ReengagementPlanner: Sendable {
    /// Ventana diurna local: desde `startHour`:00 hasta `endHour`:00 inclusive.
    public var startHour = 10
    public var endHour = 20
    /// "Cerca": ningún aviso de inactividad a menos de esto de otro aviso de Anima.
    public var spacing: TimeInterval = 3 * 3600
    /// Tope diario compartido con el resto de lo proactivo (§5.8: ≤4/día).
    public var dailyCap = 4
    /// Tope del back-off.
    public var maxGapDays = 14
    /// Avisos programados por adelantado (cubren el back-off sin que la app corra).
    public var chainLength = 4

    /// El calendario se lee en CADA cálculo: tras un viaje (otra zona horaria,
    /// sin relanzar la app) la ventana diurna sigue siendo la del lugar donde
    /// está el dueño. En la app es `Calendar.autoupdatingCurrent`.
    private let calendarProvider: @Sendable () -> Calendar
    public var calendar: Calendar { calendarProvider() }

    public init(calendar: Calendar) {
        self.calendarProvider = { calendar }
    }

    public init(calendarProvider: @escaping @Sendable () -> Calendar = { Calendar.autoupdatingCurrent }) {
        self.calendarProvider = calendarProvider
    }

    /// Días entre el aviso `index` y el anterior (o el último uso): N, N, 2N, 2N, 4N…
    /// Cada dos ignorados seguidos el intervalo se duplica, hasta `maxGapDays`.
    public func gapDays(base: Int, index: Int) -> Int {
        let doublings = min(index / 2, 8)
        return min(base * (1 << doublings), maxGapDays)
    }

    /// La hora a la que suele hablarle, metida en la ventana diurna.
    public func preferredTime(lastUse: Date) -> (hour: Int, minute: Int) {
        preferredTime(lastUse: lastUse, calendar: calendar)
    }

    func preferredTime(lastUse: Date, calendar: Calendar) -> (hour: Int, minute: Int) {
        let hour = calendar.component(.hour, from: lastUse)
        let minute = calendar.component(.minute, from: lastUse) >= 30 ? 30 : 0
        if hour < startHour { return (startHour, 0) }
        if hour >= endHour { return (endHour, 0) }
        return (hour, minute)
    }

    /// Las fechas de la cadena que aún no pasaron (las pasadas cuentan como
    /// entregadas e ignoradas: hacen avanzar el back-off).
    /// `load(day)`: avisos proactivos extra de ese día que no son notificaciones
    /// programadas (p. ej. pulsos del deseo ya entregados hoy).
    public func chain(lastUse: Date, days: Int, others: [LocalNotificationRequest], now: Date,
                      load: (Date) -> Int = { _ in 0 }) -> [Date] {
        let calendar = self.calendar
        let preferred = preferredTime(lastUse: lastUse, calendar: calendar)
        var cursor = lastUse
        var out: [Date] = []
        var index = 0
        while out.count < chainLength, index < 64 {
            let target = calendar.date(byAdding: .day, value: gapDays(base: days, index: index),
                                       to: calendar.startOfDay(for: cursor)) ?? cursor
            let fire = place(on: target, preferred: preferred, others: others, load: load, calendar: calendar)
            index += 1
            cursor = fire
            if fire > now { out.append(fire) }
        }
        return out
    }

    /// El primer hueco libre del día (o de los 2 siguientes): la hora preferida o
    /// la más cercana en pasos de 30 min dentro de la ventana, lejos de otros avisos
    /// y sin pasar el tope diario. Si no hay, el día +3 a la hora preferida.
    func place(on day: Date, preferred: (hour: Int, minute: Int), others: [LocalNotificationRequest],
               load: (Date) -> Int, calendar: Calendar) -> Date {
        for offset in 0...2 {
            guard let candidateDay = calendar.date(byAdding: .day, value: offset, to: day) else { continue }
            let busy = others.flatMap { Self.occurrences(of: $0, on: candidateDay, calendar: calendar) }
            guard busy.count + load(candidateDay) < dailyCap else { continue }
            for slot in slots(on: candidateDay, preferred: preferred, calendar: calendar)
            where !busy.contains(where: { abs($0.timeIntervalSince(slot)) < spacing }) {
                return slot
            }
        }
        let fallbackDay = calendar.date(byAdding: .day, value: 3, to: day) ?? day
        return at(preferred.hour, preferred.minute, on: fallbackDay, calendar: calendar)
    }

    /// Horas candidatas del día ordenadas por cercanía a la preferida.
    func slots(on day: Date, preferred: (hour: Int, minute: Int), calendar: Calendar) -> [Date] {
        let base = preferred.hour * 60 + preferred.minute
        let all = stride(from: startHour * 60, through: endHour * 60, by: 30)
        return all.sorted { abs($0 - base) == abs($1 - base) ? $0 > $1 : abs($0 - base) < abs($1 - base) }
            .map { at($0 / 60, $0 % 60, on: day, calendar: calendar) }
    }

    private func at(_ hour: Int, _ minute: Int, on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    /// Cuándo cae una notificación programada en un día dado (0 o 1 vez).
    static func occurrences(of request: LocalNotificationRequest, on day: Date, calendar: Calendar) -> [Date] {
        switch request.trigger {
        case .immediate:
            return []
        case .at(let date):
            return calendar.isDate(date, inSameDayAs: day) ? [date] : []
        case .calendar(let components, _):
            if let weekday = components.weekday, weekday != calendar.component(.weekday, from: day) { return [] }
            if let dayOfMonth = components.day, dayOfMonth != calendar.component(.day, from: day) { return [] }
            guard let date = calendar.date(bySettingHour: components.hour ?? 0, minute: components.minute ?? 0,
                                           second: 0, of: day) else { return [] }
            return [date]
        }
    }
}

// MARK: - Las preguntas de respaldo (sin sueño aún, o el sueño no dejó ninguna)

public enum ReengagementFallback {
    /// Cálidas, abiertas y sin nada sensible. Rotan; ninguna se repite seguido.
    public static let questions = [
        "¿Cómo vas hoy?",
        "¿Qué tienes en mente esta semana?",
        "¿Cómo has estado de ánimo estos días?",
        "Hace rato no hablamos, ¿cómo estás?",
        "¿Qué fue lo mejor de tu semana hasta ahora?",
        "¿Hay algo que te tenga entusiasmado últimamente?",
        "¿Qué planes tienes para los próximos días?",
        "¿Algo que te esté dando vueltas en la cabeza?",
        "¿En qué te puedo ayudar a organizarte esta semana?",
        "¿Cómo te fue con lo que tenías pendiente?",
    ]

    static let refPrefix = "fallback-"

    static func ref(_ index: Int) -> String { refPrefix + String(index) }

    static func index(of ref: String) -> Int? {
        guard ref.hasPrefix(refPrefix), let index = Int(ref.dropFirst(refPrefix.count)),
              questions.indices.contains(index) else { return nil }
        return index
    }

    static func text(for ref: String) -> String? { index(of: ref).map { questions[$0] } }
}

// MARK: - Lo que puede ir en un push

/// Una pregunta solo entra al push si es corta, es pregunta y no expone nada
/// sensible (política de #38 ronda 2): sin cifras ni comillas, y nada de salud,
/// dinero, asuntos legales, adicciones ni pareja — en español y en inglés.
/// Por PALABRA (sin tildes ni mayúsculas): una raíz solo cuenta al inicio de
/// una palabra ("terapeuta", pero no "plataforma" por "plata"); las palabras
/// ambiguas van enteras y lo que solo es sensible en frase, como frase
/// ("tarjeta de crédito" sí, "tarjeta de cumpleaños" no). Determinista; el
/// prompt del sueño pide lo mismo.
public enum ReengagementTextGuard {
    public static let maxLength = 90
    public static let minLength = 8

    /// Raíces: cuentan si una palabra EMPIEZA por ellas.
    static let sensitiveStems = [
        // salud (es)
        "medic", "doctor", "doctora", "diagnos", "enferm", "pastilla", "terapi", "terapeut", "tratamient",
        "psiquiatr", "psicolog", "depresi", "ansiedad", "cancer", "diabet", "embaraz", "hospital", "cirug",
        "operaci", "sintoma", "clinic", "colesterol", "vacun", "dieta",
        // salud (en)
        "therap", "diagnos", "illness", "surger", "pregnan", "depress", "anxiet", "prescription", "symptom",
        // dinero (es)
        "dinero", "deuda", "prestam", "salari", "sueldo", "millon", "dolar", "credito", "hipotec", "factur",
        "arriendo", "alquiler", "inversi", "invert", "cripto", "bitcoin", "ahorr", "impuest", "nomina",
        // dinero (en)
        "loan", "debt", "mortgage", "salar", "paycheck", "money", "invest", "crypto", "saving", "taxes",
        // legal
        "abogad", "demand", "juicio", "juzgad", "multa", "lawyer", "lawsuit", "attorney",
        // adicciones
        "alcohol", "drog", "adicci", "rehab", "resaca", "drunk", "addict", "hangover",
        // pareja
        "divorci", "separaci", "infidel", "amante", "divorc", "breakup", "boyfriend", "girlfriend", "cheating",
    ]

    /// Palabras enteras (cortas o ambiguas como raíz).
    static let sensitiveWords: Set<String> = [
        "plata", "peso", "pesos", "kilos", "kg", "banco", "bancos", "pagar", "pago", "pagos", "pagaste", "renta",
        "novio", "novia", "pareja", "ex", "meds", "med", "pill", "pills", "doc", "sick", "rent", "bank",
        "pay", "paid", "court", "drugs", "drug", "rx", "ivf",
    ]

    /// Frases (ya plegadas: sin tildes, minúsculas).
    static let sensitivePhrases = [
        "tarjeta de credito", "tarjeta de debito", "credit card", "presion arterial", "examen de sangre",
        "blood test", "blood pressure",
    ]

    public static func isAllowed(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (minLength...maxLength).contains(trimmed.count), trimmed.contains("?") else { return false }
        if trimmed.contains(where: { $0.isNumber }) { return false }
        if trimmed.contains(where: { "\"«»“”$€%".contains($0) }) { return false }
        return sensitiveHit(trimmed) == nil
    }

    /// La raíz, palabra o frase sensible que encontró (nil = limpia).
    static func sensitiveHit(_ text: String) -> String? {
        let words = folded(text).split { !$0.isLetter }.map(String.init)
        if let word = words.first(where: sensitiveWords.contains) { return word }
        for word in words {
            if let stem = sensitiveStems.first(where: { word.hasPrefix($0) }) { return stem }
        }
        let joined = " " + words.joined(separator: " ") + " "
        return sensitivePhrases.first { joined.contains(" \($0) ") }
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
    }

    /// Clave de comparación (sin tildes, mayúsculas ni signos) para no repetir.
    static func key(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .filter { $0.isLetter || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }
}
