// VoiceInvocations.swift — "Hey Meta, start Anima" (DAT 1.0 `VoiceInvocationsStream`,
// experimental). Puerto FINO + orquestación PURA, testeable en macOS:
//   · el adapter real (App/Glasses/VoiceInvocationsController.swift) abre un
//     stream por device conectado TEMPRANO (init del AppModel: cold-launch por
//     voz se captura antes de la UI) y entrega `VoiceInvocationRequest`s;
//   · el orquestador decide qué hacer con cada invocación y responde SIEMPRE
//     exactamente una vez por el response handle (sin respuesta Meta AI queda
//     esperando y muestra su fallback). El SDK rechaza respuestas duplicadas,
//     así que el ACK refleja el resultado de ABRIR la sesión (rápido: no espera
//     al display) — no se puede mandar success y luego failure.
//   · LaunchApp: sesión ya viva → success idempotente (no se crea otra);
//     dormida → espera acotada a que el device sea elegible (cold-launch: el
//     DAT aún no reportó devices) → ensureActive → success + Home card;
//     no elegible / falla → failure.
//   · invocaciones que llegan antes de que el cuerpo exista (bootstrap aún sin
//     DB) se encolan y se resuelven al `bind`; si nunca llega → failure.

import Foundation

public enum VoiceInvocationKind: String, Sendable, Equatable {
    case launchApp
    /// Una invocación que el SDK entregó pero Anima no sabe atender.
    case unsupported
}

/// El response handle del SDK (`sendSuccess`/`sendFailure`). Devuelve si se entregó.
public protocol VoiceInvocationResponder: Sendable {
    func respond(success: Bool, output: String?) async -> Bool
}

public struct VoiceInvocationRequest: Sendable {
    public let kind: VoiceInvocationKind
    public let deviceId: String
    public let responder: any VoiceInvocationResponder

    public init(kind: VoiceInvocationKind, deviceId: String, responder: any VoiceInvocationResponder) {
        self.kind = kind
        self.deviceId = deviceId
        self.responder = responder
    }
}

/// `VoiceInvocationError` del SDK, reducido a lo que la app distingue.
public enum VoiceInvocationsFailure: Sendable, Equatable {
    /// `invalidWearablesInterface` (SDK sin configurar) o init request rechazado:
    /// sin el permiso Voice Invocation aprobado en el portal de Meta no hay stream.
    case notPermitted
    /// `deviceNotFound` / `channelNotConnected`: transitorio, se reintenta al conectar.
    case deviceUnavailable
    case other(String)
}

public enum VoiceInvocationsPortEvent: Sendable {
    /// Devices con stream abierto (tras cada start/stop por device).
    case listening(deviceIds: [String])
    case invocation(VoiceInvocationRequest)
    case failure(VoiceInvocationsFailure)
}

/// El puerto: el adapter real usa `VoiceInvocationsStream` (@MainActor en el SDK).
@MainActor
public protocol VoiceInvocationsPort: AnyObject {
    /// Abre los streams (listeners ANTES de `start(deviceIdentifier:)`). Idempotente.
    func start(_ handler: @escaping @MainActor (VoiceInvocationsPortEvent) -> Void)
    func stop()
}

/// Resultado de pedirle al cuerpo que se encienda por voz.
public enum VoiceLaunchOutcome: Sendable, Equatable {
    case activated
    case alreadyActive
    case failed(String)

    public var succeeded: Bool {
        if case .failed = self { return false }
        return true
    }
}

/// Lo que el orquestador necesita del cuerpo (GlassesActivation lo cumple).
public protocol VoiceLaunchTarget: Sendable {
    func launchFromVoice(eligibilityTimeout: TimeInterval) async -> VoiceLaunchOutcome
    /// Tras el ACK: espera el display y deja la Home card si no hay vista.
    func presentHome() async
}

/// Estado visible en Ajustes → Gafas.
public enum VoiceInvocationsStatus: Sendable, Equatable {
    case unavailable          // build sin SDK (UI tests / simulador sin config)
    case starting
    case waitingForGlasses    // stream listo, ningún device conectado aún
    case listening(devices: Int)
    case needsPortalPermission
    case failed(String)

    public var label: String {
        switch self {
        case .unavailable: return "No disponible en esta build"
        case .starting: return "Iniciando…"
        case .waitingForGlasses: return "Activo · esperando las gafas"
        case .listening: return "Activo"
        case .needsPortalPermission:
            return "Requiere permiso Voice Invocation aprobado en el portal de Meta"
        case .failed(let why): return "Inactivo · \(why)"
        }
    }

    public var isActive: Bool {
        switch self {
        case .listening, .waitingForGlasses: return true
        default: return false
        }
    }
}

/// Telemetría `voice_invocation`: una fila por fase (received / ack / result).
public struct VoiceInvocationRecord: Sendable, Equatable {
    public enum Phase: String, Sendable { case received, ack, result }
    public var phase: Phase
    public var kind: VoiceInvocationKind
    public var deviceId: String
    /// ack: success|failure · result: activated|alreadyActive|failed|unsupported|timeout.
    public var outcome: String?
    /// ack: el SDK confirmó la entrega de la respuesta.
    public var delivered: Bool?
    public var detail: String?
    public var latencyMs: Double?

    public init(phase: Phase, kind: VoiceInvocationKind, deviceId: String, outcome: String? = nil,
                delivered: Bool? = nil, detail: String? = nil, latencyMs: Double? = nil) {
        self.phase = phase
        self.kind = kind
        self.deviceId = deviceId
        self.outcome = outcome
        self.delivered = delivered
        self.detail = detail
        self.latencyMs = latencyMs
    }
}

@MainActor
public final class VoiceInvocationOrchestrator {
    public private(set) var status: VoiceInvocationsStatus

    private let port: (any VoiceInvocationsPort)?
    private let eligibilityTimeout: TimeInterval
    private let bindTimeout: TimeInterval
    private let now: @Sendable () -> Date

    private var target: (any VoiceLaunchTarget)?
    private var record: (@Sendable (VoiceInvocationRecord) -> Void)?
    private var bufferedRecords: [VoiceInvocationRecord] = []
    private var pending: [(VoiceInvocationRequest, Date)] = []
    private var bindDeadline: Task<Void, Never>?
    /// Un LaunchApp en vuelo: los que lleguen mientras tanto comparten su resultado.
    private var inFlight: Task<VoiceLaunchOutcome, Never>?
    private var observers: [UUID: AsyncStream<VoiceInvocationsStatus>.Continuation] = [:]
    private var started = false

    /// Tests: tareas de manejo en curso (para esperar a que terminen).
    private(set) var handling: [Task<Void, Never>] = []

    public init(port: (any VoiceInvocationsPort)?, eligibilityTimeout: TimeInterval = 4,
                bindTimeout: TimeInterval = 8, now: @escaping @Sendable () -> Date = { Date() }) {
        self.port = port
        self.eligibilityTimeout = eligibilityTimeout
        self.bindTimeout = bindTimeout
        self.now = now
        self.status = port == nil ? .unavailable : .starting
    }

    /// Abre el stream lo antes posible (init del AppModel). Idempotente.
    public func start() {
        guard !started, let port else { return }
        started = true
        port.start { [weak self] event in self?.handle(event) }
    }

    public func stop() {
        port?.stop()
        started = false
        bindDeadline?.cancel()
    }

    /// Enchufa el cuerpo y la telemetría (bootstrap, ya con DB). Resuelve lo encolado.
    public func bind(target: any VoiceLaunchTarget, record: (@Sendable (VoiceInvocationRecord) -> Void)? = nil) {
        self.target = target
        if let record {
            self.record = record
            bufferedRecords.forEach(record)
            bufferedRecords = []
        }
        bindDeadline?.cancel()
        bindDeadline = nil
        let queued = pending
        pending = []
        for (request, received) in queued { spawn(request, received: received) }
    }

    public func statusUpdates() -> AsyncStream<VoiceInvocationsStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<VoiceInvocationsStatus>.makeStream()
        continuation.yield(status)
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers[id] = nil }
        }
        return stream
    }

    // MARK: - Eventos del puerto

    func handle(_ event: VoiceInvocationsPortEvent) {
        switch event {
        case .listening(let ids):
            setStatus(ids.isEmpty ? .waitingForGlasses : .listening(devices: ids.count))
        case .failure(let failure):
            switch failure {
            case .notPermitted:
                setStatus(.needsPortalPermission)
            case .deviceUnavailable:
                if !status.isActive { setStatus(.waitingForGlasses) }
            case .other(let why):
                if !status.isActive { setStatus(.failed(why)) }
            }
        case .invocation(let request):
            let received = now()
            emit(.init(phase: .received, kind: request.kind, deviceId: request.deviceId))
            if target == nil {
                pending.append((request, received))
                armBindDeadline()
            } else {
                spawn(request, received: received)
            }
        }
    }

    private func spawn(_ request: VoiceInvocationRequest, received: Date) {
        handling.append(Task { [weak self] in await self?.process(request, received: received) })
    }

    private func armBindDeadline() {
        guard bindDeadline == nil else { return }
        let timeout = bindTimeout
        bindDeadline = Task { [weak self] in
            guard (try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))) != nil else { return }
            await self?.expirePending()
        }
    }

    func expirePending() async {
        bindDeadline = nil
        let expired = pending
        pending = []
        for (request, received) in expired {
            await answer(request, success: false, outcome: "timeout", detail: "la app no terminó de arrancar",
                         received: received)
        }
    }

    // MARK: - Orquestación

    func process(_ request: VoiceInvocationRequest, received: Date) async {
        guard request.kind == .launchApp else {
            await answer(request, success: false, outcome: "unsupported", detail: "invocación no soportada",
                         received: received)
            return
        }
        guard let target else { return }
        let outcome: VoiceLaunchOutcome
        if let inFlight {
            outcome = await inFlight.value
        } else {
            let timeout = eligibilityTimeout
            let task = Task { await target.launchFromVoice(eligibilityTimeout: timeout) }
            inFlight = task
            outcome = await task.value
            inFlight = nil
        }
        switch outcome {
        case .activated:
            await answer(request, success: true, outcome: "activated", detail: nil, received: received)
            await target.presentHome()
        case .alreadyActive:
            await answer(request, success: true, outcome: "alreadyActive", detail: nil, received: received)
        case .failed(let why):
            await answer(request, success: false, outcome: "failed", detail: why, received: received)
        }
    }

    private func answer(_ request: VoiceInvocationRequest, success: Bool, outcome: String, detail: String?,
                        received: Date) async {
        let delivered = await request.responder.respond(success: success, output: success ? nil : detail)
        let latency = now().timeIntervalSince(received) * 1000
        emit(.init(phase: .ack, kind: request.kind, deviceId: request.deviceId,
                   outcome: success ? "success" : "failure", delivered: delivered, latencyMs: latency))
        emit(.init(phase: .result, kind: request.kind, deviceId: request.deviceId,
                   outcome: outcome, detail: detail, latencyMs: latency))
    }

    private func emit(_ row: VoiceInvocationRecord) {
        if let record { record(row) } else { bufferedRecords.append(row) }
    }

    private func setStatus(_ next: VoiceInvocationsStatus) {
        guard next != status else { return }
        status = next
        for continuation in observers.values { continuation.yield(next) }
    }
}
