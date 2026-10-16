// Sensorimotor.swift — el cuerpo iOS (§5.7): registro de tools, ejecución con
// permisos 2-capas y timeout. Es el punto único por donde pasa toda acción del
// agente sobre el mundo — los permisos los aplica el harness, no el prompt.

import Foundation

/// Una tool del Sensorimotor: además del contrato base (`spec`, `execute`),
/// declara la naturaleza de cada invocación para la PermissionPolicy.
public protocol SensorimotorTool: HarnessTool {
    /// Aferente (lee) o eferente (actúa) según el input concreto.
    func kind(for input: JSONValue) -> ToolKind
    /// Nombre de la operación (para allowlist granular y el diff de confirmación).
    func operation(for input: JSONValue) -> String
    /// Resumen legible de la acción para el `ask` in-chat.
    func confirmationSummary(for input: JSONValue) -> String
    /// Guard de CUERPO (doc 05 §6.1: body presente → permiso → ACI). Si el
    /// cuerpo que la tool necesita no está (gafas desconectadas), devuelve el
    /// error SIN pedir confirmación ni ejecutar. nil = cuerpo presente.
    func bodyGuard(for input: JSONValue) async -> ToolResult?
}

extension SensorimotorTool {
    public func kind(for input: JSONValue) -> ToolKind { .afferent }
    public func operation(for input: JSONValue) -> String {
        input["action"]?.stringValue ?? "default"
    }
    public func confirmationSummary(for input: JSONValue) -> String {
        "\(spec.name): \(operation(for: input))"
    }
    public func bodyGuard(for input: JSONValue) async -> ToolResult? { nil }
}

/// Resultado de una ejecución sin prompt (SkillRunner): la policy decide igual.
public enum PreauthorizedExecution: Sendable, Equatable {
    case executed(ToolResult)
    case needsConfirmation(ConfirmationRequest)   // la policy pidió ask: NO se ejecutó
    case denied(ToolResult)                       // deny / tool desconocida (fail-closed)
}

public actor Sensorimotor {
    private var tools: [String: any SensorimotorTool]
    private let policy: PermissionPolicy
    private let confirmation: ConfirmationProvider
    private let timeout: TimeInterval

    public init(tools: [any SensorimotorTool] = [],
                policy: PermissionPolicy = .init(),
                confirmation: ConfirmationProvider = FailClosedConfirmation(),
                timeout: TimeInterval = 30) {
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.spec.name, $0) })
        self.policy = policy
        self.confirmation = confirmation
        self.timeout = timeout
    }

    public func register(_ tool: any SensorimotorTool) {
        tools[tool.spec.name] = tool
    }

    /// Las specs de todas las tools client-side, en orden alfabético estable
    /// (§5.1: jamás reordenar mid-session).
    public func toolSpecs() -> [ToolSpec] {
        tools.values.map(\.spec).sorted { $0.name < $1.name }
    }

    public func has(_ name: String) -> Bool { tools[name] != nil }

    /// Ejecuta una tool aplicando la capa 1 (PermissionPolicy) y un timeout.
    /// Fail-closed: tool desconocida = deny; eferente sin confirmación = no ejecuta.
    public func execute(name: String, input: JSONValue, surface: SurfaceID = .phoneChat) async -> ToolResult {
        // Lo que la superficie niega se niega ANTES de la política: "Autorizar
        // siempre" no deja borrar desde Siri ni actuar con riesgo desde el carro.
        if surface != .phoneChat, let tool = tools[name], tool.kind(for: input) == .efferent {
            let request = ConfirmationRequest(tool: name, operation: tool.operation(for: input),
                                              summary: tool.confirmationSummary(for: input), input: input,
                                              surface: surface)
            if let refusal = SurfaceConfirmationRouter.refusal(for: request) {
                await confirmation.refused(request)
                return ToolResult(content: refusal, isError: true, isRejection: true)
            }
        }
        switch await executePreauthorized(name: name, input: input) {
        case .executed(let result), .denied(let result):
            return result
        case .needsConfirmation(var request):
            request.surface = surface
            if let refusal = SurfaceConfirmationRouter.refusal(for: request) {
                await confirmation.refused(request)
                return ToolResult(content: refusal, isError: true, isRejection: true)
            }
            // Turno ya cancelado: no se le pide confirmación a nadie (un sheet
            // abierto retendría la sesión).
            guard !Task.isCancelled else { return Self.notStartedResult(name) }
            let approved = await confirmation.confirm(request)
            // El confirmador se cerró por la cancelación del turno, no por el dueño.
            guard !Task.isCancelled else { return Self.notStartedResult(name) }
            guard approved else {
                return ToolResult(content: "Acción cancelada: el dueño no la confirmó.", isError: true, isRejection: true)
            }
            guard let tool = tools[name] else { return Self.unknown(name) }
            return await runWithTimeout(tool: tool, input: input)
        }
    }

    /// Camino del SkillRunner (System 1): MISMA capa 1 que `execute` — los
    /// invariantes no se delegan — pero SIN pedir confirmación: si la policy dice
    /// `ask`, devuelve `.needsConfirmation` sin ejecutar ni molestar al dueño.
    public func executePreauthorized(name: String, input: JSONValue) async -> PreauthorizedExecution {
        guard let tool = tools[name] else { return .denied(Self.unknown(name)) }
        if let absent = await tool.bodyGuard(for: input) { return .denied(absent) }
        let kind = tool.kind(for: input)
        let operation = tool.operation(for: input)
        switch policy.decide(tool: name, known: true, kind: kind, operation: operation) {
        case .deny:
            return .denied(ToolResult(content: "Acción no permitida por la política de permisos.", isError: true))
        case .ask:
            return .needsConfirmation(ConfirmationRequest(
                tool: name, operation: operation,
                summary: tool.confirmationSummary(for: input), input: input))
        case .allow:
            return .executed(await runWithTimeout(tool: tool, input: input))
        }
    }

    private static func unknown(_ name: String) -> ToolResult {
        ToolResult(content: "Tool desconocida o no permitida: \(name)", isError: true)
    }

    /// Una llamada, un resultado (el tool_use queda pareado):
    /// - la tool termina → su resultado;
    /// - el turno se cancela → resultado de cancelación YA, y la cancelación
    ///   llega a la tool (una cooperativa se corta: la cámara de las gafas, una
    ///   escritura en curso);
    /// - gana el timeout → error de timeout y la tool se abandona (se le pide
    ///   cancelar, sin esperarla): una tool que ignora la cancelación no retiene
    ///   el turno.
    private func runWithTimeout(tool: any SensorimotorTool, input: JSONValue) async -> ToolResult {
        let name = tool.spec.name
        let cancelled = Self.cancelledResult(name)
        guard !Task.isCancelled else { return Self.notStartedResult(name) }
        let timeout = self.timeout
        let expired = Self.timeoutResult(name, timeout: timeout)
        let call = ToolCall(cancelled: cancelled)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ToolResult, Never>) in
                let first = FirstWins(continuation)
                let work = Task { first.resume(await tool.execute(input)) }
                let timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    first.resume(expired)
                }
                first.onResume = {
                    timer.cancel()
                    work.cancel()
                }
                call.start(first, work: work)
            }
        } onCancel: {
            call.cancel()
        }
    }

    /// Aviso honesto cuando una tool se cortó o se abandonó: pudo haber escrito
    /// igual (ninguna tool eferente revisa la cancelación), no duplicar un create.
    static let mayHaveCompleted = "La acción pudo haberse completado igual: verifica su estado antes de reintentarla."

    /// La tool estaba corriendo cuando el turno se canceló.
    static func cancelledResult(_ name: String) -> ToolResult {
        ToolResult(content: "La tool '\(name)' se interrumpió porque el turno se canceló. " + mayHaveCompleted,
                   isError: true, isCancellation: true)
    }

    /// El turno ya estaba cancelado: la tool ni arrancó.
    static func notStartedResult(_ name: String) -> ToolResult {
        ToolResult(content: "La tool '\(name)' no se ejecutó: el turno se canceló.", isError: true, isCancellation: true)
    }

    /// El modelo puede reintentar tras un timeout: la tool abandonada pudo
    /// haber completado la acción igual (no duplicar un create).
    static func timeoutResult(_ name: String, timeout: TimeInterval) -> ToolResult {
        ToolResult(content: "La tool '\(name)' excedió el timeout de \(seconds(timeout)). " + mayHaveCompleted,
                   isError: true)
    }

    /// "30s", "0.1s", "1.5s": sin "0s" para topes de menos de un segundo.
    static func seconds(_ value: TimeInterval) -> String {
        if value == value.rounded() { return "\(Int(value))s" }
        return String(format: "%.1fs", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: ".0s", with: "s")
    }
}

/// Una llamada en vuelo: la cancelación del turno (que puede llegar antes de
/// que arranque) resuelve con el resultado de cancelación y corta la tool.
private final class ToolCall: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelled: ToolResult
    private var first: FirstWins<ToolResult>?
    private var work: Task<Void, Never>?
    private var isCancelled = false

    init(cancelled: ToolResult) {
        self.cancelled = cancelled
    }

    func start(_ first: FirstWins<ToolResult>, work: Task<Void, Never>) {
        let cancelNow = lock.withLock { () -> Bool in
            self.first = first
            self.work = work
            return isCancelled
        }
        if cancelNow { finish(first, work) }
    }

    func cancel() {
        let pending = lock.withLock { () -> (FirstWins<ToolResult>, Task<Void, Never>)? in
            isCancelled = true
            guard let first, let work else { return nil }
            return (first, work)
        }
        if let pending { finish(pending.0, pending.1) }
    }

    private func finish(_ first: FirstWins<ToolResult>, _ work: Task<Void, Never>) {
        work.cancel()
        first.resume(cancelled)
    }
}
