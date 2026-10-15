// SiriTurn.swift — hablar con Anima por Siri sin abrir el teléfono (batch 10 #2).
// El turno es uno más del AgentLoop (superficie `.siri`, mismo transcript que el
// chat, persistido igual) y se espeja en el chat. Siri tiene paciencia acotada:
// con un deadline, Siri dice "Te respondo en el chat" y el turno sigue; su
// respuesta queda en el chat y `settled` avisa que llegó tarde. Nunca se afirma
// un éxito: el texto final es el del loop (ActionClaimGuard / ToolFailureNotice
// ya lo corrigieron), un error se dice como error y una acción que pide el ok
// del dueño se le pregunta (o se cancela, fail-closed, si ya nadie escucha).

import Foundation

public enum SiriTurn {
    /// Lo que Siri espera antes de soltar el turno al chat.
    public static let deadline: Duration = .seconds(12)
    public static let spokenLimit = HUDSummary.spokenLimit
    public static let chatTail = "El resto te lo dejo en el chat."
    public static let deferredText = "Te respondo en el chat."
    public static let declinedDefault = "Prefiero no hacer eso. Dime qué buscas y encontramos otra vía."
    public static let busyText = "Estoy terminando otra respuesta en el chat. Pregúntame en un momento."
    public static let emptyText = "No te escuché. ¿Qué le quieres decir a Anima?"
    public static let offlineText = "Estoy sin conexión. Inténtalo cuando vuelva la red o escríbeme en el chat."

    public enum Outcome: Sendable, Equatable {
        /// La respuesta completa del turno (la que quedó en el chat).
        case replied(String)
        case declined(String)
        /// El turno falló sin respuesta (red, key, modelo local no disponible…).
        case failed(String)
        /// Una acción del turno espera el ok del dueño (resumen de la acción).
        case needsApproval(String)
        /// Venció el deadline: el turno sigue y su respuesta queda en el chat.
        case deferred
        /// Ya hay un turno del chat en curso.
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
            let reason = HUDSummary.clip(HUDSummary.plain(message), 140)
            return "No pude responderte: \(reason)"
        case .needsApproval(let summary):
            return "Para eso necesito tu confirmación (\(summary)). Ábrelo en el chat de Anima."
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

    /// El aviso cuando la respuesta llegó tarde (Siri ya había soltado el turno).
    public static func lateNotice(_ outcome: Outcome) -> String? {
        switch outcome {
        case .replied(let text), .declined(let text):
            return HUDSummary.clip(plainSpeech(text), 160)
        case .failed:
            return "No pude responderte lo que me pediste por Siri. Míralo en el chat."
        default:
            return nil
        }
    }

    /// Markdown y emojis de aviso fuera; si no cabe, las oraciones que caben +
    /// la remisión al chat.
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
        HUDSummary.plain(text)
            .replacingOccurrences(of: "⚠️", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Un turno de Siri sobre el loop. `ask` arranca el turno y espera hasta que
/// termina, vence el deadline o pide confirmación; `resume` vuelve a esperar
/// tras resolver la confirmación; `release` marca que Siri ya contestó: desde
/// ahí una confirmación nueva se cancela (nadie puede darla) y, si la respuesta
/// llega después, `settled` la recibe para avisar. `settled` corre UNA vez al
/// cerrar el turno (nil si el dueño ya la oyó).
public actor SiriTurnRunner {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let runner: any TurnRunner
    private let sessionId: SessionID
    private let deadline: Duration
    private let pollInterval: Duration
    private let pendingApproval: @Sendable () async -> String?
    private let declineApproval: @Sendable () async -> Void
    private let deliver: @Sendable (SurfaceContent) async -> Void
    private let settled: @Sendable (SiriTurn.Outcome?) async -> Void
    private let sleep: Sleep

    private var turn: Task<SiriTurn.Outcome, Never>?
    private var baseline: String?
    private var final: SiriTurn.Outcome?
    private var heard = false
    private var released = false
    private var didSettle = false

    public init(runner: any TurnRunner, sessionId: SessionID, deadline: Duration = SiriTurn.deadline,
                pollInterval: Duration = .milliseconds(250),
                pendingApproval: @escaping @Sendable () async -> String? = { nil },
                declineApproval: @escaping @Sendable () async -> Void = {},
                deliver: @escaping @Sendable (SurfaceContent) async -> Void = { _ in },
                settled: @escaping @Sendable (SiriTurn.Outcome?) async -> Void = { _ in },
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.runner = runner
        self.sessionId = sessionId
        self.deadline = deadline
        self.pollInterval = pollInterval
        self.pendingApproval = pendingApproval
        self.declineApproval = declineApproval
        self.deliver = deliver
        self.settled = settled
        self.sleep = sleep
    }

    public func ask(_ text: String) async -> SiriTurn.Outcome {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard turn == nil else { return .busy }
        guard !said.isEmpty else {
            await settle(nil)
            return .empty
        }
        baseline = await pendingApproval()
        await deliver(.userTurn(text: said, origin: .siri))
        let stream = await runner.run(sessionId: sessionId, content: [AudioTool.transcriptBlock(said)],
                                      surface: .siri)
        let deliver = self.deliver
        let task = Task { () -> SiriTurn.Outcome in
            var collector = SiriTurnCollector()
            for await event in stream { collector.apply(event) }
            let outcome = collector.outcome
            if let mirror = SiriTurnCollector.mirror(outcome) { await deliver(mirror) }
            return outcome
        }
        turn = task
        Task { await self.finished(await task.value) }
        return await wait()
    }

    /// Tras resolver la confirmación pedida: vuelve a esperar el turno.
    public func resume() async -> SiriTurn.Outcome {
        guard turn != nil else { return .failed("No había un turno en curso.") }
        baseline = await pendingApproval()
        return await wait()
    }

    /// Siri ya contestó: lo que falte del turno corre sin nadie escuchando.
    public func release() async {
        released = true
        if final != nil { await settle(heard ? nil : final) }
        guard final == nil else { return }
        let poll = pollInterval
        let sleep = self.sleep
        Task {
            while self.final == nil {
                if await self.hasNewApproval() { await self.declineApproval() }
                try? await sleep(poll)
            }
        }
    }

    private func hasNewApproval() async -> Bool {
        guard let pending = await pendingApproval() else { return false }
        return pending != baseline
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
        let baseline = self.baseline
        let pendingApproval = self.pendingApproval
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
                    if let pending = await pendingApproval(), pending != baseline {
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

/// Resuelve la continuación con el PRIMER resultado; los demás se ignoran.
private final class FirstWins<Value: Sendable>: @unchecked Sendable {
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
/// las gafas: lo retraído se quita, el aviso de fallo va al frente.
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
        if text.isEmpty { return .failed(failure ?? "No obtuve respuesta.") }
        return .replied(text)
    }

    /// Lo que se espeja en el chat al cerrar (el turno del dueño ya se espejó).
    static func mirror(_ outcome: SiriTurn.Outcome) -> SurfaceContent? {
        switch outcome {
        case .replied(let text): .assistantTurn(text: text, origin: .siri)
        case .declined(let text): .declined(text: text, origin: .siri)
        case .failed(let message): .status(message)
        default: nil
        }
    }
}
