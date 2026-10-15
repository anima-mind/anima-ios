// SiriTurn.swift — hablar con Anima por Siri sin abrir el teléfono (batch 10 #2).
// El turno es uno más del AgentLoop (superficie `.siri`, mismo transcript que el
// chat, persistido igual) y se espeja en el chat. Siri tiene paciencia acotada:
// con un deadline, Siri dice "Te respondo en el chat" y el turno sigue; su
// respuesta queda en el chat y `settled` avisa que llegó tarde. Nunca se afirma
// un éxito: el texto final es el del loop (ActionClaimGuard / ToolFailureNotice
// ya lo corrigieron), un error se dice como error (aunque hubiera texto a medias)
// y una acción que pide el ok del dueño se le pregunta por Siri; las
// confirmaciones de Siri viven en su propio buzón (SiriApprovals): jamás toca
// las del chat o las gafas, y cuando Siri ya contestó, las suyas se niegan.

import Foundation

public enum SiriTurn {
    /// Lo que Siri espera antes de soltar el turno al chat.
    public static let deadline: Duration = .seconds(12)
    /// Tope duro del turno entero: después se cancela (la base no queda retenida).
    public static let hardLimit: Duration = .seconds(90)
    public static let spokenLimit = HUDSummary.spokenLimit
    public static let chatTail = "El resto te lo dejo en el chat."
    public static let deferredText = "Te respondo en el chat."
    public static let declinedDefault = "Prefiero no hacer eso. Dime qué buscas y encontramos otra vía."
    public static let busyText = "Sigo con lo anterior. Te respondo en el chat y me preguntas en un momento."
    public static let emptyText = "No te escuché. ¿Qué le quieres decir a Anima?"
    public static let offlineText = "Estoy sin conexión. Inténtalo cuando vuelva la red o escríbeme en el chat."
    public static let timeoutText = "Se acabó el tiempo para responder. Inténtalo de nuevo en el chat."
    public static let lateNoticeText = "Tu respuesta está en el chat."
    public static let noAnswerText = "No obtuve respuesta."

    public enum Outcome: Sendable, Equatable {
        /// La respuesta completa del turno (la que quedó en el chat).
        case replied(String)
        case declined(String)
        /// El turno falló (red, key, modelo local, tope de tiempo…), aunque
        /// alcanzara a decir algo antes.
        case failed(String)
        /// Una acción del turno espera el ok del dueño (resumen de la acción).
        case needsApproval(String)
        /// Venció el deadline: el turno sigue y su respuesta queda en el chat.
        case deferred
        /// Ya hay otro turno en curso (chat, gafas u otro Siri).
        case busy
        case empty
        case offline
        /// La app no puede correr turnos (sin onboarding, sin key…): por qué.
        case notReady(String)
    }

    /// Lo que Siri dice: texto plano, acotado a una respuesta hablada.
    public static func spoken(_ outcome: Outcome) -> String {
        switch outcome {
        case .replied(let text), .declined(let text):
            return speech(text)
        case .failed(let message):
            let reason = HUDSummary.clip(plainSpeech(message), 140)
            return "No pude responderte: \(reason)"
        case .needsApproval:
            // Siri ya no la va a preguntar y su buzón la niega al soltar el turno.
            return "Eso necesitaba tu confirmación y no la tuve, así que no lo hice. Te dejo el detalle en el chat."
        case .deferred: return deferredText
        case .busy: return busyText
        case .empty: return emptyText
        case .offline: return offlineText
        case .notReady(let reason): return reason
        }
    }

    /// La pregunta que Siri hace antes de una acción que pide el ok del dueño.
    public static func confirmationPrompt(_ summary: String) -> String {
        "Para eso necesito tu ok: \(summary). ¿Lo hago?"
    }

    /// El aviso cuando la respuesta llegó tarde (Siri ya había soltado el turno):
    /// genérico, sin contenido de la respuesta en la pantalla bloqueada.
    public static func lateNotice(_ outcome: Outcome) -> String? {
        switch outcome {
        case .replied, .declined, .failed: return lateNoticeText
        default: return nil
        }
    }

    /// Markdown y emojis fuera; si no cabe, las oraciones que caben + la
    /// remisión al chat.
    static func speech(_ text: String) -> String {
        let plain = plainSpeech(text)
        guard plain.count > spokenLimit else { return plain }
        var said = ""
        for sentence in HUDSummary.sentences(plain) {
            let next = said.isEmpty ? sentence : said + " " + sentence
            if next.count > spokenLimit { break }
            said = next
        }
        if said.isEmpty { said = HUDSummary.clip(plain, spokenLimit) }
        return said + " " + chatTail
    }

    static func plainSpeech(_ text: String) -> String {
        let scalars = Array(HUDSummary.plain(text).unicodeScalars)
        var kept = String.UnicodeScalarView()
        for (i, scalar) in scalars.enumerated() {
            let next = i + 1 < scalars.count ? scalars[i + 1] : nil
            if !isPictograph(scalar, next: next) { kept.append(scalar) }
        }
        let words = String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Lo que quedó suelto al quitar un emoji: " ." → ".".
        return words.replacingOccurrences(of: #" +([.,;:!?…])"#, with: "$1", options: .regularExpression)
    }

    /// Emoji y pictogramas (con sus selectores, tonos y uniones). No toca
    /// letras, dígitos, "#", "*", ni símbolos de texto como ™ o ©.
    static func isPictograph(_ scalar: Unicode.Scalar, next: Unicode.Scalar? = nil) -> Bool {
        switch scalar.value {
        case 0x200D, 0xFE0E, 0xFE0F, 0x20E3: return true
        case 0x1F3FB...0x1F3FF, 0xE0020...0xE007F: return true
        case 0x1F000...0x1FAFF, 0x2600...0x27BF, 0x2B00...0x2BFF: return true
        default: break
        }
        let p = scalar.properties
        if p.isEmojiPresentation { return true }
        // Un símbolo de texto pedido como emoji ("⚠️" = ⚠ + FE0F).
        return p.isEmoji && scalar.value > 0x7F && next?.value == 0xFE0F
    }
}

/// El ÚNICO turno en vuelo sobre la sesión: chat, gafas y Siri lo piden antes
/// de correr (y antes de espejar nada); si otro lo tiene, el nuevo dice que
/// está ocupado. `begin` entrega un TOKEN y solo ese token la suelta: un
/// `end` tardío jamás libera el turno de otro. Se suelta cuando el turno de
/// verdad terminó (`end(_:after:)` espera al productor del loop, con tope), y
/// avisa cada cambio a sus observadores (el chat se ve ocupado).
public final class TurnGate: @unchecked Sendable {
    public struct Token: Sendable, Equatable {
        public let id = UUID()
        public let surface: SurfaceID
    }

    /// Lo que se espera al productor antes de soltar igual (no queda tomada
    /// para siempre si un provider no respeta la cancelación).
    public static let idleLimit: Duration = .seconds(10)

    private let lock = NSLock()
    private var holder: Token?
    private var observers: [UUID: @Sendable (SurfaceID?) -> Void] = [:]

    public init() {}

    public var current: SurfaceID? { lock.withLock { holder?.surface } }

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (SurfaceID?) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = handler }
        return id
    }

    public func removeObserver(_ id: UUID) {
        _ = lock.withLock { observers.removeValue(forKey: id) }
    }

    public var observerCount: Int { lock.withLock { observers.count } }

    public func begin(_ surface: SurfaceID) -> Token? {
        let token = Token(surface: surface)
        let notify = lock.withLock { () -> [@Sendable (SurfaceID?) -> Void]? in
            guard holder == nil else { return nil }
            holder = token
            return Array(observers.values)
        }
        guard let notify else { return nil }
        notify.forEach { $0(surface) }
        return token
    }

    public func end(_ token: Token) {
        let notify = lock.withLock { () -> [@Sendable (SurfaceID?) -> Void]? in
            guard holder == token else { return nil }
            holder = nil
            return Array(observers.values)
        }
        notify?.forEach { $0(nil) }
    }

    /// Suelta cuando el loop ya no produce (aunque el stream se cortara antes):
    /// un `begin` justo después nunca la encuentra tomada. Con tope.
    public func end(_ token: Token, after runner: any TurnRunner, limit: Duration = TurnGate.idleLimit) async {
        await Self.waitIdle(runner, limit: limit)
        end(token)
    }

    /// Espera a que el runner no produzca, como mucho `limit`. false = venció.
    @discardableResult
    public static func waitIdle(_ runner: any TurnRunner, limit: Duration) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let first = FirstWins(continuation)
            let idle = Task {
                await runner.waitUntilIdle()
                first.resume(true)
            }
            let timer = Task {
                try? await Task.sleep(for: limit)
                first.resume(false)
            }
            first.onResume = {
                timer.cancel()
                _ = idle
            }
        }
    }

    public static func busyText(_ holder: SurfaceID?) -> String {
        switch holder {
        case .siri: "Estoy respondiendo algo que me pediste por Siri. Inténtalo en un momento."
        case .glassesHUD: "Estoy respondiendo en tus gafas. Inténtalo en un momento."
        default: "Estoy terminando otra respuesta. Inténtalo en un momento."
        }
    }
}

/// El buzón de confirmaciones de los turnos de Siri (SurfaceConfirmationRouter
/// le manda SOLO las de `.siri`). Abierto mientras Siri puede preguntarle al
/// dueño; cerrado, toda confirmación se niega (fail-closed).
public final class SiriApprovals: ConfirmationProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var listening = false
    private var request: ConfirmationRequest?
    private var continuation: CheckedContinuation<Bool, Never>?

    public init() {}

    public var pendingSummary: String? { lock.withLock { request?.summary } }

    public func open() { lock.withLock { listening = true } }

    /// Siri ya no escucha: la pendiente (si hay) y las que vengan se niegan.
    public func close() {
        let waiting = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            listening = false
            return take()
        }
        waiting?.resume(returning: false)
    }

    public func resolve(_ approved: Bool) {
        lock.withLock { take() }?.resume(returning: approved)
    }

    public func confirm(_ request: ConfirmationRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            let accepted = lock.withLock { () -> Bool in
                guard listening, self.continuation == nil else { return false }
                self.continuation = continuation
                self.request = request
                return true
            }
            if !accepted { continuation.resume(returning: false) }
        }
    }

    private func take() -> CheckedContinuation<Bool, Never>? {
        let waiting = continuation
        continuation = nil
        request = nil
        return waiting
    }
}

/// Un turno de Siri sobre el loop. `ask` arranca el turno y espera hasta que
/// termina, vence el deadline o pide confirmación; `resume` vuelve a esperar
/// tras resolverla; `release` marca que Siri ya contestó (cierra el buzón) y,
/// si la respuesta llega después, `settled` la recibe para avisar. `settled`
/// corre UNA vez al cerrar el turno (nil si el dueño ya la oyó). `cancel` (o el
/// tope duro) corta el turno: la base no queda retenida por un provider colgado.
public actor SiriTurnRunner {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let runner: any TurnRunner
    private let sessionId: SessionID
    private let approvals: SiriApprovals
    private let deadline: Duration
    private let hardLimit: Duration
    private let pollInterval: Duration
    private let deliver: @Sendable (SurfaceContent) async -> Void
    private let settled: @Sendable (SiriTurn.Outcome?) async -> Void
    private let sleep: Sleep

    private var turn: Task<SiriTurn.Outcome, Never>?
    private var final: SiriTurn.Outcome?
    private var heard = false
    private var released = false
    private var didSettle = false
    private let cut = CutFlag()

    public init(runner: any TurnRunner, sessionId: SessionID, approvals: SiriApprovals = SiriApprovals(),
                deadline: Duration = SiriTurn.deadline, hardLimit: Duration = SiriTurn.hardLimit,
                pollInterval: Duration = .milliseconds(250),
                deliver: @escaping @Sendable (SurfaceContent) async -> Void = { _ in },
                settled: @escaping @Sendable (SiriTurn.Outcome?) async -> Void = { _ in },
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.runner = runner
        self.sessionId = sessionId
        self.approvals = approvals
        self.deadline = deadline
        self.hardLimit = hardLimit
        self.pollInterval = pollInterval
        self.deliver = deliver
        self.settled = settled
        self.sleep = sleep
    }

    public func ask(_ text: String) async -> SiriTurn.Outcome {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard turn == nil, !didSettle else { return .busy }
        guard !said.isEmpty else {
            await settle(nil)
            return .empty
        }
        approvals.open()
        await deliver(.userTurn(text: said, origin: .siri))
        let stream = await runner.run(sessionId: sessionId, content: [AudioTool.transcriptBlock(said)],
                                      surface: .siri)
        let deliver = self.deliver
        let cut = self.cut
        let runner = self.runner
        let task = Task { () -> SiriTurn.Outcome in
            var collector = SiriTurnCollector()
            for await event in stream { collector.apply(event) }
            // Cortado o no, el turno termina cuando el loop deja de producir
            // (con tope: un productor que ignora la cancelación no lo retiene).
            await TurnGate.waitIdle(runner, limit: TurnGate.idleLimit)
            let outcome = cut.value ? .failed(SiriTurn.timeoutText) : collector.outcome
            if let mirror = SiriTurnCollector.mirror(outcome) { await deliver(mirror) }
            return outcome
        }
        turn = task
        Task { await self.finished(await task.value) }
        let limit = hardLimit
        let sleep = self.sleep
        Task {
            try? await sleep(limit)
            self.cancel()
        }
        return await wait()
    }

    /// Tras resolver la confirmación pedida: vuelve a esperar el turno.
    public func resume() async -> SiriTurn.Outcome {
        guard turn != nil else { return .failed("No había un turno en curso.") }
        return await wait()
    }

    /// Siri ya contestó: el buzón se cierra (fail-closed) y lo que falte del
    /// turno corre sin nadie escuchando.
    public func release() async {
        released = true
        approvals.close()
        if let final { await settle(heard ? nil : final) }
    }

    /// Corta el turno en vuelo (tope duro o fin del tiempo en background).
    public func cancel() {
        guard final == nil, let turn else { return }
        cut.mark()
        approvals.close()
        turn.cancel()
    }

    private enum Race: Sendable {
        case done(SiriTurn.Outcome)
        case deadline
        case approval(String)
    }

    private func wait() async -> SiriTurn.Outcome {
        guard let turn else { return .deferred }
        let deadline = self.deadline
        let poll = self.pollInterval
        let sleep = self.sleep
        let approvals = self.approvals
        // Carrera sin task group: esperar `turn.value` no se cancela, y un grupo
        // esperaría al turno entero aunque gane el deadline.
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Race, Never>) in
            let first = FirstWins(continuation)
            let done = Task { first.resume(.done(await turn.value)) }
            let timer = Task {
                try? await sleep(deadline)
                first.resume(.deadline)
            }
            let watcher = Task {
                while !Task.isCancelled {
                    if let pending = approvals.pendingSummary {
                        first.resume(.approval(pending))
                        return
                    }
                    do { try await sleep(poll) } catch { return }
                }
            }
            first.onResume = {
                timer.cancel()
                watcher.cancel()
                _ = done
            }
        }
        switch result {
        case .done(let outcome):
            heard = true
            return outcome
        case .deadline:
            return .deferred
        case .approval(let summary):
            return .needsApproval(summary)
        }
    }

    private func finished(_ outcome: SiriTurn.Outcome) async {
        final = outcome
        if released { await settle(heard ? nil : outcome) }
    }

    private func settle(_ late: SiriTurn.Outcome?) async {
        guard !didSettle else { return }
        didSettle = true
        await settled(late)
    }
}

private final class CutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cut = false
    var value: Bool { lock.withLock { cut } }
    func mark() { lock.withLock { cut = true } }
}

/// Resuelve la continuación con el PRIMER resultado; los demás se ignoran.
final class FirstWins<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var cleanup: (@Sendable () -> Void)?
    private var resumed = false

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    var onResume: (@Sendable () -> Void)? {
        get { lock.withLock { cleanup } }
        set {
            let runNow = lock.withLock { () -> Bool in
                cleanup = newValue
                return resumed
            }
            if runNow { newValue?() }
        }
    }

    func resume(_ value: Value) {
        let (continuation, cleanup) = lock.withLock { () -> (CheckedContinuation<Value, Never>?, (@Sendable () -> Void)?) in
            guard !resumed else { return (nil, nil) }
            resumed = true
            defer { self.continuation = nil }
            return (self.continuation, self.cleanup)
        }
        continuation?.resume(returning: value)
        cleanup?()
    }
}

/// LoopEvent → la respuesta del turno, con la MISMA semántica que el chat y
/// las gafas: lo retraído se quita, el aviso de fallo va al frente, y un error
/// o una parada a mitad gana a lo que se alcanzó a decir.
struct SiriTurnCollector {
    var reply = ""
    var committed = ""
    var refused = false
    var failure: String?

    mutating func apply(_ event: LoopEvent) {
        switch event {
        case .textDelta(let delta): reply += delta
        case .refused: refused = true
        case .assistantMessage: committed = reply
        case .retracted: reply = committed
        case .toolFailure(let notice) where !reply.hasPrefix(notice):
            let body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            reply = body.isEmpty ? notice : notice + "\n\n" + body
        case .error(let message): failure = message
        case .stopped(let stop): failure = "Turno detenido (\(stop))."
        default: break
        }
    }

    var outcome: SiriTurn.Outcome {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if refused { return .declined(text.isEmpty ? SiriTurn.declinedDefault : text) }
        if let failure { return .failed(failure) }
        if text.isEmpty { return .failed(SiriTurn.noAnswerText) }
        return .replied(text)
    }

    /// Lo que se espeja en el chat al cerrar (el turno del dueño ya se espejó).
    static func mirror(_ outcome: SiriTurn.Outcome) -> SurfaceContent? {
        switch outcome {
        case .replied(let text): .assistantTurn(text: text, origin: .siri)
        case .declined(let text): .declined(text: text, origin: .siri)
        case .failed(let message): .turnFailed(text: message, origin: .siri)
        default: nil
        }
    }
}
