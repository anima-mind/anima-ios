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
    /// Existe pero ya no está activo (un recordatorio ya marcado hecho): se
    /// puede hablar de él, no moverlo ni volver a marcarlo.
    public var closed: Bool
    /// Cuándo se marcó hecho (deshacer: solo los de las últimas 24 h).
    public var doneAt: Date?
    /// La hora del recordatorio citado ("a la misma hora").
    public var at: Date?

    public init(ref: ChatQuoteRef, title: String, excerpt: String, detail: String? = nil, missing: Bool = false,
                closed: Bool = false, doneAt: Date? = nil, at: Date? = nil) {
        self.ref = ref
        self.title = Self.oneLine(title, limit: Self.titleLimit)
        self.excerpt = Self.oneLine(excerpt, limit: Self.excerptLimit)
        self.detail = detail
        self.missing = missing
        self.closed = closed
        self.doneAt = doneAt
        self.at = at
    }

    /// ¿Se puede actuar sobre lo citado? (existe y sigue activo).
    public var isActionable: Bool { !missing && !closed }

    public var id: String { ref.token }
    public var kind: ChatQuoteKind { ref.kind }

    public static let titleLimit = 80
    public static let excerptLimit = 160

    // MARK: Codable (claves explícitas; detail/missing opcionales para crecer sin romper)

    enum CodingKeys: String, CodingKey { case kind, id, title, excerpt, detail, missing, closed, doneAt = "done_at", at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = ChatQuoteRef(kind: try c.decode(ChatQuoteKind.self, forKey: .kind), id: try c.decode(String.self, forKey: .id))
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        excerpt = try c.decodeIfPresent(String.self, forKey: .excerpt) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        missing = try c.decodeIfPresent(Bool.self, forKey: .missing) ?? false
        closed = try c.decodeIfPresent(Bool.self, forKey: .closed) ?? false
        doneAt = try c.decodeIfPresent(Double.self, forKey: .doneAt).map(Date.init(timeIntervalSince1970:))
        at = try c.decodeIfPresent(Double.self, forKey: .at).map(Date.init(timeIntervalSince1970:))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ref.kind, forKey: .kind)
        try c.encode(ref.id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(excerpt, forKey: .excerpt)
        try c.encodeIfPresent(detail, forKey: .detail)
        if missing { try c.encode(true, forKey: .missing) }
        if closed { try c.encode(true, forKey: .closed) }
        try c.encodeIfPresent(doneAt?.timeIntervalSince1970, forKey: .doneAt)
        try c.encodeIfPresent(at?.timeIntervalSince1970, forKey: .at)
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

    /// VoiceOver: "Respondiendo a recordatorio Abonar 5M a la deuda: …",
    /// "Respondiendo a tu mensaje: …", "Respondiendo al mensaje de Anima: …".
    public var accessibilityLabel: String {
        let subject: String
        switch kind {
        case .reminder: subject = "recordatorio \(title)"
        case .goal: subject = "meta \(title)"
        case .checkIn: subject = "seguimiento \(title)"
        case .message: subject = title == Self.ownerTitle ? "tu mensaje" : "al mensaje de \(title)"
        }
        let lead = kind == .message && title != Self.ownerTitle ? "Respondiendo " : "Respondiendo a "
        return lead + subject + (excerpt.isEmpty ? "" : ": \(excerpt)")
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
/// siguen sabiendo de qué se habla). La UI lo quita al pintar (`split`).
/// Remoto: con el id y la tool que actúa sobre él. Local (3B, 4096 tokens): sin
/// el id (el 3B leía los ids como texto) y recortado; las tools locales de la
/// cita (`move_reminder`, `done_reminder`) actúan sobre el recordatorio citado.
public enum ChatQuoteContext {
    public static let marker = "[El dueño responde a "
    /// Topes del bloque del modelo local: la línea entera queda < 80 tokens
    /// (medido con el tokenizer del modelo de Apple en ChatQuoteTokenTests).
    public static let compactExcerptLimit = 90
    public static let compactTitleLimit = 50
    public static let compactDetailLimit = 45

    /// El bloque de la cita se reconoce por su ESTRUCTURA, no solo por el texto
    /// (review #43: un dueño que escribe "[El dueño responde a esto…]" no puede
    /// desaparecer su turno): es el PRIMER bloque, de texto, con el marcador, y
    /// le sigue al menos otro bloque (lo que dijo el dueño). Lo que el dueño
    /// escribe o dicta viaja siempre como un solo bloque (o tras una foto).
    public static func split(_ blocks: [ContentBlock]) -> (line: String?, rest: [ContentBlock]) {
        guard blocks.count >= 2, case .text(let first) = blocks[0], first.hasPrefix(marker) else {
            return (nil, blocks)
        }
        return (first.trimmingCharacters(in: .whitespacesAndNewlines), Array(blocks.dropFirst()))
    }

    public static func withoutBlock(_ blocks: [ContentBlock]) -> [ContentBlock] { split(blocks).rest }

    /// La respuesta abre con un bloque entre corchetes que repite la cita (el
    /// marcador o el título citado): lo que queda sin él (o un acuse breve si
    /// no queda nada). nil si no hay eco. El cierre es el "]" que balancea el
    /// "[" inicial ("Pagar [luz] del mes" no se corta).
    public static func withoutEcho(_ text: String, quote: ChatQuote? = nil) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Variante sin corchete: "El dueño responde a tu recordatorio «…» (…). Resto".
        let bare = String(marker.dropFirst())
        if trimmed.hasPrefix(bare) {
            var depth = 0
            var end = trimmed.endIndex
            for index in trimmed.indices {
                let ch = trimmed[index]
                if ch == "(" || ch == "«" { depth += 1 }
                if ch == ")" || ch == "»" { depth -= 1 }
                if (ch == "." || ch == "]"), depth <= 0 {
                    end = trimmed.index(after: index)
                    break
                }
            }
            let clean = trimmed[end...].trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? echoFallback : clean
        }
        guard trimmed.hasPrefix("["), let close = balancedClose(trimmed) else { return nil }
        let inside = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
        let echoes = trimmed.hasPrefix(marker)
            || (quote.map { !$0.title.isEmpty && inside.contains($0.title) } ?? false)
        guard echoes else { return nil }
        let clean = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? echoFallback : clean
    }

    /// El "]" que cierra el "[" del inicio (con corchetes anidados).
    static func balancedClose(_ text: String) -> String.Index? {
        var depth = 0
        for index in text.indices {
            switch text[index] {
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    public static let echoFallback = "Aquí estoy. ¿Qué quieres hacer con eso?"

    /// "tu recordatorio «Abonar 5M…»" desde la línea de la cita: lo citado, sin
    /// ids ni instrucciones (para el resumen de la conversación). El título va
    /// entre «»: se corta en su cierre ("Llamar (urgente) a mamá" queda entero).
    public static func summary(_ line: String) -> String? {
        guard line.hasPrefix(marker) else { return nil }
        let body = String(line.dropFirst(marker.count))
        let paren = body.range(of: " (")?.lowerBound
        if let open = body.firstIndex(of: "«"), paren.map({ open < $0 }) ?? true {
            var depth = 0
            for index in body[open...].indices {
                if body[index] == "«" { depth += 1 }
                if body[index] == "»" {
                    depth -= 1
                    if depth == 0 { return String(body[...index]) }
                }
            }
        }
        let cut = body.range(of: " (")?.lowerBound ?? body.firstIndex(where: { $0 == "]" || $0 == ":" }) ?? body.endIndex
        var head = body[..<cut].trimmingCharacters(in: .whitespaces)
        if head.hasSuffix(".") { head.removeLast() }
        return head.isEmpty ? nil : head
    }

    /// `localTools`: las tools de la cita que viajan en ESTE turno (modelo local,
    /// solo si el dueño las pidió): la línea las nombra (medido: sin el nombre
    /// el 3B listaba en vez de mover).
    public static func block(_ quote: ChatQuote, compact: Bool, localTools: Set<String> = []) -> ContentBlock {
        // El salto doble final separa la cita del mensaje del dueño: el armado
        // local toma "lo último tras \n\n" como el turno del dueño.
        .text(line(quote, compact: compact, localTools: localTools) + "\n")
    }

    public static func line(_ quote: ChatQuote, compact: Bool, localTools: Set<String> = []) -> String {
        compact ? compactLine(quote, localTools: localTools) : fullLine(quote)
    }

    static func fullLine(_ q: ChatQuote) -> String {
        // Solo un id con forma de id real llega al modelo (un deep link
        // manipulado ya no pasa ChatQuoteRef(token:); esto cubre lo demás).
        let id = ChatQuoteRef.isValidId(q.ref.id) ? q.ref.id : "?"
        let detail = q.detail.map { ", \($0)" } ?? ""
        let excerpt = q.excerpt.isEmpty ? "" : ": «\(q.excerpt)»"
        // Lo que ya no existe no lleva id: no hay nada sobre qué actuar.
        if q.missing {
            switch q.kind {
            case .reminder:
                return marker + "un recordatorio que ya no existe («\(q.title)»). No intentes editarlo: dile que ya no está y ofrécele crear uno nuevo si lo quiere.]"
            case .goal, .checkIn:
                return marker + "una meta que ya no existe («\(q.title)»). No intentes ajustarla: dile que ya no está.]"
            case .message:
                return marker + "un mensaje que ya no está en el chat («\(q.title)»).]"
            }
        }
        switch q.kind {
        case .reminder:
            return marker + "tu recordatorio «\(q.title)» (id \(id)\(detail))\(excerpt). Si pide moverlo, posponerlo o borrarlo, usa anima_reminders con ese id. Márcalo hecho SOLO si afirma que ya lo hizo («ya lo pagué», «ya lo hice»); un «listo», «ya», «gracias» o un «ya lo hago» es ambiguo: pregúntale antes de tocarlo.]"
        case .goal:
            return marker + "su meta «\(q.title)» (id \(id)\(detail))\(excerpt). Si pide ajustarla, su seguimiento o darla por lograda, usa goals con ese id.]"
        case .checkIn:
            return marker + "tu seguimiento de su meta «\(q.title)» (id \(id)\(detail))\(excerpt). Si te cuenta cómo le fue, anótalo con goals (record_checkin) sobre ese id.]"
        case .message:
            let who = q.title == ChatQuote.ownerTitle ? "su propio mensaje" : "tu mensaje"
            return marker + "\(who)\(excerpt)]"
        }
    }

    static func compactLine(_ q: ChatQuote, localTools: Set<String> = []) -> String {
        let excerpt = ChatQuote.oneLine(q.excerpt, limit: compactExcerptLimit)
        let title = ChatQuote.oneLine(q.title, limit: compactTitleLimit)
        let detail = q.detail.map { " (\(ChatQuote.oneLine($0, limit: compactDetailLimit)))" } ?? ""
        if q.missing {
            switch q.kind {
            case .reminder: return marker + "un recordatorio que ya no existe: «\(title)». No lo cambies; díselo.]"
            case .goal, .checkIn: return marker + "una meta que ya no existe: «\(title)». Díselo.]"
            case .message: return marker + "un mensaje que ya no está.]"
            }
        }
        switch q.kind {
        case .reminder:
            var hint = ""
            if localTools.contains("move_reminder") { hint += " Para moverlo usa move_reminder." }
            if localTools.contains("done_reminder") { hint += " Para darlo por hecho usa done_reminder." }
            if localTools.contains("undo_done") { hint += " Ya estaba hecho; para deshacerlo usa undo_done." }
            return marker + "tu recordatorio «\(title)»\(detail).\(hint)]"
        case .goal:
            return marker + "su meta «\(title)»\(detail).]"
        case .checkIn:
            return marker + "tu seguimiento de su meta «\(title)»\(detail).]"
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
                         excerpt: reminder.spokenMessage, detail: detail,
                         closed: reminder.status == .done || reminder.status == .cancelled,
                         doneAt: reminder.status == .done ? reminder.doneAt : nil, at: reminder.fireAt)
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
