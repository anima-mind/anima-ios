// ChatQuote.swift — "responder citando" (como el reply de WhatsApp). El dueño
// cita un recordatorio, una meta, el seguimiento de una meta o un mensaje del
// chat; la cita viaja con su turno: el composer la pinta arriba del campo, la
// burbuja arriba del texto, se persiste en `turn_event.quote_json` y el modelo
// la recibe como un bloque de contexto estructurado (con el id, para que sus
// tools actúen sobre lo citado). Lo citado que ya no existe se degrada: la cita
// lo dice y el modelo no intenta editarlo.

import Foundation

public struct ChatQuote: Sendable, Codable, Equatable, Identifiable {
    public var ref: ChatQuoteRef
    /// Título corto: el recordatorio ("Abonar 5M a la deuda"), la meta, o quién
    /// dijo el mensaje ("Anima" / "Tú").
    public var title: String
    /// Una línea de lo citado: lo que ella dirá, el estado de la meta, el mensaje.
    public var excerpt: String
    /// Contexto para el modelo: "programado jue 29 oct, 6:33 p. m.", "activa · racha 3 días".
    public var detail: String?
    /// Lo citado ya no existe (borrado/cancelado): se cita igual, honesto.
    public var missing: Bool

    public init(ref: ChatQuoteRef, title: String, excerpt: String, detail: String? = nil, missing: Bool = false) {
        self.ref = ref
        self.title = Self.oneLine(title, limit: Self.titleLimit)
        self.excerpt = Self.oneLine(excerpt, limit: Self.excerptLimit)
        self.detail = detail
        self.missing = missing
    }

    public var id: String { ref.token }
    public var kind: ChatQuoteKind { ref.kind }

    public static let titleLimit = 80
    public static let excerptLimit = 160

    // MARK: Codable (claves explícitas; detail/missing opcionales para crecer sin romper)

    enum CodingKeys: String, CodingKey { case kind, id, title, excerpt, detail, missing }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = ChatQuoteRef(kind: try c.decode(ChatQuoteKind.self, forKey: .kind), id: try c.decode(String.self, forKey: .id))
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        excerpt = try c.decodeIfPresent(String.self, forKey: .excerpt) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        missing = try c.decodeIfPresent(Bool.self, forKey: .missing) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ref.kind, forKey: .kind)
        try c.encode(ref.id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(excerpt, forKey: .excerpt)
        try c.encodeIfPresent(detail, forKey: .detail)
        if missing { try c.encode(true, forKey: .missing) }
    }

    var json: String? {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func decode(_ json: String?) -> ChatQuote? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ChatQuote.self, from: data)
    }

    // MARK: Lo que se pinta

    /// La etiqueta de la barra: "Recordatorio · Abonar 5M a la deuda", "Meta · …",
    /// "Seguimiento · …", o el autor del mensaje ("Anima", "Tú").
    public var label: String {
        switch kind {
        case .reminder: return "Recordatorio · \(title)"
        case .goal: return "Meta · \(title)"
        case .checkIn: return "Seguimiento · \(title)"
        case .message: return title
        }
    }

    /// VoiceOver: "Respondiendo a recordatorio Abonar 5M a la deuda: …".
    public var accessibilityLabel: String {
        "Respondiendo a \(Self.kindName(kind)) \(title)" + (excerpt.isEmpty ? "" : ": \(excerpt)")
    }

    static func kindName(_ kind: ChatQuoteKind) -> String {
        switch kind {
        case .reminder: return "recordatorio"
        case .goal: return "meta"
        case .checkIn: return "seguimiento"
        case .message: return "mensaje de"
        }
    }

    /// Lo citado ya no existe: el título que ya se conocía (o uno genérico) y la
    /// línea que lo dice.
    public static func missing(_ ref: ChatQuoteRef, title: String? = nil) -> ChatQuote {
        let known = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback: String
        let excerpt: String
        switch ref.kind {
        case .reminder: fallback = "Recordatorio"; excerpt = "Este recordatorio ya no existe."
        case .goal: fallback = "Meta"; excerpt = "Esta meta ya no existe."
        case .checkIn: fallback = "Seguimiento"; excerpt = "Esta meta ya no existe."
        case .message: fallback = "Mensaje"; excerpt = "Este mensaje ya no está."
        }
        return ChatQuote(ref: ref, title: known?.isEmpty == false ? known! : fallback, excerpt: excerpt, missing: true)
    }

    /// Una sola línea recortada con "…" (la barra y el contexto del modelo local).
    static func oneLine(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - El bloque de contexto que recibe el modelo

/// La cita como contexto del turno: un bloque de texto que va ANTES del mensaje
/// del dueño en el mismo turno user (se persiste con él: los turnos siguientes
/// siguen sabiendo de qué se habla). La UI lo quita al pintar (`isBlock`).
/// Remoto: con el id y la tool que actúa sobre él. Local (3B, 4096 tokens): sin
/// el id (el 3B leía los ids como texto) y recortado; las tools locales de la
/// cita (`move_reminder`, `done_reminder`) actúan sobre el recordatorio citado.
public enum ChatQuoteContext {
    public static let marker = "[El dueño responde a "
    /// Tope del extracto en el bloque del modelo local.
    public static let compactExcerptLimit = 90

    /// ¿Es el bloque de contexto de una cita? (la UI no lo pinta).
    public static func isBlock(_ text: String) -> Bool {
        text.hasPrefix(marker) && text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("]")
    }

    public static func block(_ quote: ChatQuote, compact: Bool) -> ContentBlock {
        // El salto doble final separa la cita del mensaje del dueño: el armado
        // local toma "lo último tras \n\n" como el turno del dueño.
        .text(line(quote, compact: compact) + "\n")
    }

    public static func line(_ quote: ChatQuote, compact: Bool) -> String {
        compact ? compactLine(quote) : fullLine(quote)
    }

    static func fullLine(_ q: ChatQuote) -> String {
        let id = q.ref.id
        let detail = q.detail.map { ", \($0)" } ?? ""
        let excerpt = q.excerpt.isEmpty ? "" : ": «\(q.excerpt)»"
        if q.missing {
            switch q.kind {
            case .reminder:
                return marker + "un recordatorio que ya no existe (id \(id), «\(q.title)»). No intentes editarlo: dile que ya no está y ofrécele crear uno nuevo si lo quiere.]"
            case .goal, .checkIn:
                return marker + "una meta que ya no existe (id \(id), «\(q.title)»). No intentes ajustarla: dile que ya no está.]"
            case .message:
                return marker + "un mensaje que ya no está en el chat («\(q.title)»).]"
            }
        }
        switch q.kind {
        case .reminder:
            return marker + "tu recordatorio «\(q.title)» (id \(id)\(detail))\(excerpt). Si pide cambiarlo, moverlo, posponerlo, darlo por hecho o borrarlo, usa anima_reminders con ese id.]"
        case .goal:
            return marker + "su meta «\(q.title)» (id \(id)\(detail))\(excerpt). Si pide ajustarla, su seguimiento o darla por lograda, usa goals con ese id.]"
        case .checkIn:
            return marker + "tu seguimiento de su meta «\(q.title)» (id \(id)\(detail))\(excerpt). Si te cuenta cómo le fue, anótalo con goals (record_checkin) sobre ese id.]"
        case .message:
            let who = q.title == ChatQuote.ownerTitle ? "su propio mensaje" : "tu mensaje"
            return marker + "\(who)\(excerpt)]"
        }
    }

    static func compactLine(_ q: ChatQuote) -> String {
        let excerpt = ChatQuote.oneLine(q.excerpt, limit: compactExcerptLimit)
        let detail = q.detail.map { " (\($0))" } ?? ""
        if q.missing {
            switch q.kind {
            case .reminder: return marker + "un recordatorio que ya no existe: «\(q.title)». No lo cambies; díselo.]"
            case .goal, .checkIn: return marker + "una meta que ya no existe: «\(q.title)». Díselo.]"
            case .message: return marker + "un mensaje que ya no está.]"
            }
        }
        switch q.kind {
        case .reminder:
            return marker + "tu recordatorio «\(q.title)»\(detail). Para moverlo usa move_reminder; para darlo por hecho, done_reminder.]"
        case .goal:
            return marker + "su meta «\(q.title)»\(detail).]"
        case .checkIn:
            return marker + "tu seguimiento de su meta «\(q.title)»\(detail).]"
        case .message:
            let who = q.title == ChatQuote.ownerTitle ? "su propio mensaje" : "tu mensaje"
            return marker + "\(who): «\(excerpt)»]"
        }
    }
}

extension ChatQuote {
    /// Autor de un mensaje citado del dueño (los de ella llevan su nombre).
    public static let ownerTitle = "Tú"

    /// El texto de un mensaje con markdown, plano (sin "**", "#", tablas): la
    /// línea que se cita.
    public static func plainExcerpt(fromMarkdown text: String) -> String {
        var parts: [String] = []
        func add(_ attributed: AttributedString) { parts.append(String(attributed.characters)) }
        for block in ChatMarkdown.blocks(text) {
            switch block {
            case .paragraph(let t), .heading(_, let t), .quote(let t): add(t)
            case .list(_, let items):
                for item in items { add(item.text); item.children.forEach { add($0.text) } }
            case .code(let code, _): parts.append(code)
            case .table, .rule: break
            }
        }
        let joined = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.isEmpty ? text : joined
    }
}

// MARK: - Resolver: ref → cita fresca (o "ya no existe")

/// Arma la cita con lo vigente en la base: el tap en un recordatorio, el deep
/// link de una notificación, el botón de una meta y el envío (que re-lee por si
/// lo citado cambió o se borró mientras el dueño escribía).
public struct ChatQuoteResolver: Sendable {
    private let reminders: AnimaReminderStore?
    private let otherModel: OtherModel?
    private let store: SymbolicStore?
    private let selfName: @Sendable () async -> String
    private let dates: AnimaDateText
    private let now: @Sendable () -> Date

    public init(reminders: AnimaReminderStore?, otherModel: OtherModel?, store: SymbolicStore? = nil,
                selfName: @escaping @Sendable () async -> String = { Birth.seed.name },
                dates: AnimaDateText = AnimaDateText(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.reminders = reminders
        self.otherModel = otherModel
        self.store = store
        self.selfName = selfName
        self.dates = dates
        self.now = now
    }

    /// `known`: la cita que ya se tenía (su título sobrevive si lo citado se borró).
    public func resolve(_ ref: ChatQuoteRef, known: ChatQuote? = nil) async -> ChatQuote {
        switch ref.kind {
        case .reminder:
            guard let reminder = await reminders?.reminder(id: ref.id), reminder.status != .cancelled else {
                return .missing(ref, title: known?.title)
            }
            return Self.quote(reminder, dates: dates)
        case .goal, .checkIn:
            guard let otherModel, let goal = await otherModel.goal(id: ref.id), goal.status != .abandoned else {
                return .missing(ref, title: known?.title)
            }
            let streak = await otherModel.streak(goalId: goal.id)
            let last = await otherModel.lastCheckIn(goalId: goal.id)
            return Self.quote(goal, kind: ref.kind, streak: streak, last: last, now: now(), dates: dates)
        case .message:
            guard let rowId = Int64(ref.id), let turn = try? store?.visibleTurn(rowId: rowId) else {
                return known ?? .missing(ref)
            }
            let title = turn.role == .user ? ChatQuote.ownerTitle : await selfName()
            return ChatQuote(ref: ref, title: title, excerpt: turn.text)
        }
    }

    /// "Abonar 5M a la deuda" · «Oye, hoy toca abonar…» · "programado jue 29 oct, 6:33 p. m.".
    public static func quote(_ reminder: AnimaReminder, dates: AnimaDateText = AnimaDateText()) -> ChatQuote {
        let when = dates.shortMoment(reminder.fireAt)
        var detail: String
        switch reminder.status {
        case .scheduled: detail = "programado \(when)"
        case .fired: detail = "entregado \(reminder.firedAt.map(dates.shortMoment) ?? when)"
        case .done: detail = "ya marcado hecho"
        case .cancelled: detail = "cancelado"
        }
        if let phrase = reminder.repeatCadence.phrase { detail += ", \(phrase)" }
        let title = reminder.text.prefix(1).uppercased() + reminder.text.dropFirst()
        return ChatQuote(ref: ChatQuoteRef(kind: .reminder, id: reminder.id), title: title,
                         excerpt: reminder.spokenMessage, detail: detail)
    }

    /// La meta (o su seguimiento): estado, seguimiento y progreso.
    public static func quote(_ goal: Goal, kind: ChatQuoteKind = .goal, streak: Int = 0, last: GoalCheckIn? = nil,
                             now: Date = Date(), dates: AnimaDateText = AnimaDateText()) -> ChatQuote {
        var parts: [String] = [statusName(goal.status)]
        if goal.checkIn.isActive { parts.append("seguimiento \(goal.checkIn.phrase)") }
        if streak > 0 { parts.append("racha \(streak) \(streak == 1 ? "día" : "días")") }
        if let last, let answer = last.answer, let at = last.answeredAt {
            parts.append("último seguimiento: \(answerName(answer)), \(dates.dayHeader(at, now: now).lowercased())")
        }
        let excerpt = kind == .checkIn
            ? CheckInScheduler.chatPrompt(for: goal)
            : goal.desiredState.label
        return ChatQuote(ref: ChatQuoteRef(kind: kind == .checkIn ? .checkIn : .goal, id: goal.id),
                         title: goal.statement, excerpt: excerpt, detail: parts.joined(separator: ", "))
    }

    static func statusName(_ status: GoalStatus) -> String {
        switch status {
        case .active: return "activa"
        case .achieved: return "lograda"
        case .abandoned: return "abandonada"
        case .pendingConfirmation: return "por confirmar"
        }
    }

    static func answerName(_ answer: CheckInAnswer) -> String {
        switch answer {
        case .yes: return "sí"
        case .partial: return "a medias"
        case .no: return "no"
        case .skipped: return "sin responder"
        }
    }
}
