// GlassesBody.swift — el actor que encarna las reglas duras del DAT (doc 05 §2,
// §3.1), calcado del DATManager de Relay (verificado en hardware):
//   · selector ÚNICO (vive en el runtime) + sesión ÚNICA, reutilizada; stop()
//     SIEMPRE en teardown → cero sesiones zombie (`noEligibleDevice` eterno).
//   · elegibilidad por compatibilidad (listener), no solo link state.
//   · ≥0.9: stateStream/errorStream TERMINAN en `.stopped` → cada sesión es una
//     GENERACIÓN nueva con sus propias suscripciones; eventos de generaciones
//     viejas se ignoran.
//   · el display duerme: cada `.started` re-envía la vista actual (cero estado
//     en las gafas).
//   · back físico / quitarse las gafas terminan la sesión → teardown limpio,
//     estado `.dormant`, la próxima interacción re-crea todo.
//   · fallos físicos → `.ailing` + RealRegister con errorClass tipado.

import Foundation

public enum GlassesAilment: String, Sendable, Equatable {
    case thermal, battery, updateRequired, versionMismatch

    /// errorClass del RealRegister (doc 05 §1).
    public var errorClass: String {
        switch self {
        case .thermal: return "glasses_thermal"
        case .battery: return "glasses_battery"
        case .updateRequired, .versionMismatch: return "glasses_version_mismatch"
        }
    }
}

public enum GlassesBodyState: Sendable, Equatable {
    case absent          // sin registro, sin device o sin configurar
    case incompatible    // linked pero el handshake/DAT app no calza
    case dormant         // elegible, sin sesión activa
    case connecting      // sesión creada, esperando session/display .started
    case active          // DeviceSession .started + Display .started
    case ailing(GlassesAilment)
}

/// Snapshot observable del cuerpo (UI de Ajustes, Mind sheet, statusLine).
public struct GlassesStatus: Sendable, Equatable {
    public var body: GlassesBodyState
    public var configured: Bool
    public var registration: GlassesRegistration
    public var deviceName: String?
    public var batteryPercent: Int?
    public var lastError: String?
    /// La última sesión la terminó el mundo (back físico, doff, apagado, dolencia),
    /// no el harness. La política de activación NO re-abre sola en ese caso.
    public var endedByDevice: Bool = false

    public init(body: GlassesBodyState = .absent, configured: Bool = false,
                registration: GlassesRegistration = .unavailable, deviceName: String? = nil,
                batteryPercent: Int? = nil, lastError: String? = nil) {
        self.body = body
        self.configured = configured
        self.registration = registration
        self.deviceName = deviceName
        self.batteryPercent = batteryPercent
        self.lastError = lastError
    }

    public var isRegistered: Bool { registration == .registered }
    public var isActive: Bool { body == .active }

    /// 1 línea de estado corporal para el system VOLÁTIL del turno (doc 05 §1,
    /// B.2). Le dice al modelo si puede usar las tools de gafas.
    public var statusLine: String {
        switch body {
        case .active:
            let battery = batteryPercent.map { " · batería \($0)%" } ?? ""
            return "Cuerpo: gafas conectadas\(battery). Puedes usar glasses_show y glasses_camera."
        case .connecting, .dormant:
            return "Cuerpo: gafas vinculadas en reposo; se activan cuando el dueño las usa. glasses_show y glasses_camera pueden fallar."
        case .incompatible:
            return "Cuerpo: gafas vinculadas pero incompatibles (actualizar la app DAT). No uses glasses_show ni glasses_camera."
        case .ailing(let ailment):
            return "Cuerpo: gafas con problema (\(Self.ailmentLabel(ailment))). No uses glasses_show ni glasses_camera."
        case .absent:
            return "Cuerpo: solo teléfono (sin gafas conectadas). No uses glasses_show ni glasses_camera."
        }
    }

    /// Etiqueta corta para la UI ("gafas conectadas", "solo teléfono"…).
    public var bodyLabel: String {
        switch body {
        case .active: return "gafas conectadas"
        case .connecting: return "gafas conectando"
        case .dormant: return "gafas en reposo"
        case .incompatible: return "gafas incompatibles"
        case .ailing(let ailment): return "gafas · \(Self.ailmentLabel(ailment))"
        case .absent: return isRegistered ? "gafas lejos" : "solo teléfono"
        }
    }

    static func ailmentLabel(_ ailment: GlassesAilment) -> String {
        switch ailment {
        case .thermal: return "temperatura alta"
        case .battery: return "batería crítica"
        case .updateRequired: return "actualizar app DAT"
        case .versionMismatch: return "versión no compatible"
        }
    }
}

public enum GlassesBodyError: Error, Equatable, CustomStringConvertible {
    case unavailable(String)
    public var description: String {
        switch self { case .unavailable(let why): return why }
    }
}

public actor GlassesBody {
    private let runtime: any GlassesRuntime
    private let realRegister: RealRegister?
    private let now: @Sendable () -> Date

    private(set) var status = GlassesStatus()
    private var device: GlassesDeviceSnapshot?
    private var ailment: GlassesAilment?

    // UNA sesión o nil (regla 2). La generación invalida suscripciones viejas.
    private var session: (any GlassesSessionPort)?
    private var display: (any GlassesDisplayPort)?
    private var displayStarted = false
    private var generation = 0
    private var sessionTasks: [Task<Void, Never>] = []

    private var currentView: HUDView?
    private var actionHandler: (@Sendable (HUDActionID) -> Void)?
    private var exitHandler: (@Sendable () -> Void)?
    private var activeWaiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [UUID: AsyncStream<GlassesStatus>.Continuation] = [:]
    private var started = false

    /// Diagnóstico/tests: cuántas sesiones se crearon en la vida del actor.
    public private(set) var sessionsCreated = 0

    public init(runtime: any GlassesRuntime, realRegister: RealRegister? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.runtime = runtime
        self.realRegister = realRegister
        self.now = now
    }

    // MARK: - Arranque y observación

    /// Configura el SDK y empieza a observar registro + devices. Idempotente.
    public func start() async {
        guard !started else { return }
        started = true
        do {
            try runtime.configure()
            status.configured = true
        } catch {
            status.configured = false
            status.lastError = "configuración: \(error)"
            publish()
            return
        }
        status.registration = await runtime.registrationState()
        recompute()
        let registrations = runtime.registrationUpdates()
        Task { [weak self] in
            for await state in registrations { await self?.onRegistration(state) }
        }
        let devices = runtime.deviceUpdates()
        Task { [weak self] in
            for await list in devices { await self?.onDevices(list) }
        }
    }

    public func currentStatus() -> GlassesStatus { status }

    /// Stream de estado: emite el actual y cada cambio.
    public func statusUpdates() -> AsyncStream<GlassesStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<GlassesStatus>.makeStream()
        continuation.yield(status)
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    /// Callbacks del HUD (acciones) y de fin de sesión (back físico / doff).
    public func setHandlers(onAction: (@Sendable (HUDActionID) -> Void)?, onExit: (@Sendable () -> Void)?) {
        actionHandler = onAction
        exitHandler = onExit
    }

    func onRegistration(_ state: GlassesRegistration) {
        status.registration = state
        if state != .registered { teardown() }
        recompute()
    }

    func onDevices(_ list: [GlassesDeviceSnapshot]) async {
        let previous = device
        device = list.first { $0.link == .connected && $0.supportsDisplay }
            ?? list.first { $0.supportsDisplay }
        status.deviceName = device?.name
        status.batteryPercent = device?.batteryPercent
        if let device, device.link == .connected,
           device.compatibility == .deviceUpdateRequired || device.compatibility == .sdkUpdateRequired,
           previous?.compatibility != device.compatibility {
            await record(errorClass: GlassesAilment.versionMismatch.errorClass, raw: "compatibility \(device.compatibility.rawValue)")
        }
        if device?.link != .connected, session != nil { teardown() }
        recompute()
    }

    /// Deriva el BodyState de registro + device + sesión + dolencia.
    private func recompute() {
        let next: GlassesBodyState
        if !status.configured || status.registration != .registered {
            next = .absent
        } else if let ailment {
            next = .ailing(ailment)
        } else if let device, device.link == .connected {
            switch device.compatibility {
            case .compatible:
                if session == nil { next = .dormant }
                else { next = displayStarted ? .active : .connecting }
            case .undefined, .deviceUpdateRequired, .sdkUpdateRequired:
                next = .incompatible
            }
        } else {
            next = .absent
        }
        status.body = next
        publish()
    }

    private func publish() {
        for continuation in observers.values { continuation.yield(status) }
    }

    /// Elegible para abrir sesión: registrado + device conectado y compatible.
    var isEligible: Bool {
        guard status.configured, status.registration == .registered,
              let device, device.link == .connected else { return false }
        return device.compatibility == .compatible
    }

    // MARK: - Registro (one-time, vía Meta AI)

    public func register() async throws {
        guard status.registration != .registered else { return }
        try await runtime.startRegistration()
    }

    public func unregister() async throws {
        teardown()
        try await runtime.startUnregistration()
    }

    @discardableResult
    public func handleURL(_ url: URL) async throws -> Bool {
        try await runtime.handleURL(url)
    }

    public func openDATGlassesAppUpdate() async throws {
        try await runtime.openDATGlassesAppUpdate()
    }

    // MARK: - Sesión única

    /// Única vía de arranque. Idempotente: si ya hay sesión, no crea otra.
    public func ensureActive() async throws {
        if session != nil { return }
        guard isEligible else {
            await record(errorClass: "glasses_unavailable", raw: "ensureActive sin device elegible")
            throw GlassesBodyError.unavailable("gafas no conectadas")
        }
        ailment = nil
        status.endedByDevice = false
        generation += 1
        let gen = generation
        let session: any GlassesSessionPort
        do {
            session = try runtime.makeSession()
        } catch {
            await record(errorClass: "glasses_unavailable", raw: "\(error)")
            status.lastError = "sesión: \(error)"
            recompute()
            throw GlassesBodyError.unavailable("no se pudo abrir la sesión de las gafas")
        }
        sessionsCreated += 1
        self.session = session
        let states = session.stateUpdates()
        let faults = session.faultUpdates()
        sessionTasks.append(Task { [weak self] in
            for await state in states { await self?.onSessionState(state, generation: gen) }
        })
        sessionTasks.append(Task { [weak self] in
            for await fault in faults { await self?.onFault(fault, generation: gen) }
        })
        do {
            try session.start()
        } catch {
            teardown()
            status.lastError = "sesión: \(error)"
            recompute()
            throw GlassesBodyError.unavailable("no se pudo arrancar la sesión de las gafas")
        }
        recompute()
    }

    /// Espera (con timeout) a que el display esté `.started`.
    public func waitUntilActive(timeout: TimeInterval = 8) async -> Bool {
        if displayStarted { return true }
        let deadline = Task { [weak self] in
            guard (try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))) != nil else { return }
            await self?.releaseWaiters()
        }
        await withCheckedContinuation { activeWaiters.append($0) }
        deadline.cancel()
        return displayStarted
    }

    private func releaseWaiters() {
        let waiters = activeWaiters
        activeWaiters = []
        waiters.forEach { $0.resume() }
    }

    func onSessionState(_ state: GlassesSessionState, generation gen: Int) async {
        guard gen == generation else { return }   // suscripción de una sesión vieja
        switch state {
        case .started:
            await attachDisplay(generation: gen)
        case .stopped:
            // Back físico, doff o apagado: la sesión murió. Teardown + aviso.
            let wasLive = session != nil
            if wasLive { status.endedByDevice = true }
            teardown()
            if wasLive { exitHandler?() }
        default:
            break
        }
    }

    private func attachDisplay(generation gen: Int) async {
        guard display == nil, let session else { return }
        do {
            let display = try session.addDisplay()
            self.display = display
            let states = display.stateUpdates()
            sessionTasks.append(Task { [weak self] in
                for await state in states { await self?.onDisplayState(state, generation: gen) }
            })
            display.start()
        } catch {
            status.lastError = "display: \(error)"
            await record(errorClass: "glasses_unavailable", raw: "addDisplay: \(error)")
            recompute()
        }
    }

    func onDisplayState(_ state: GlassesDisplayState, generation gen: Int) async {
        guard gen == generation else { return }
        switch state {
        case .started:
            displayStarted = true
            recompute()
            releaseWaiters()
            // Wake / reconexión: re-enviar la vista actual (cero estado en las gafas).
            if let currentView { await sendCurrent(currentView) }
        case .stopped:
            displayStarted = false
            recompute()
        default:
            break
        }
    }

    func onFault(_ fault: GlassesFault, generation gen: Int) async {
        guard gen == generation else { return }
        switch fault {
        case .thermalCritical, .thermalEmergency:
            await fail(.thermal, raw: "\(fault)")
        case .batteryCritical, .peakPowerShutdown:
            await fail(.battery, raw: "\(fault)")
        case .datAppUpdateRequired:
            await fail(.updateRequired, raw: "\(fault)")
        case .sdkUpdateRequired:
            await fail(.versionMismatch, raw: "\(fault)")
        case .compatibilityWarning:
            // No bloqueante (DAT 1.0): la sesión sigue; solo queda en el RealRegister.
            await record(errorClass: GlassesAilment.versionMismatch.errorClass, raw: "\(fault)")
        case .hingesClosed:
            // Se quitó las gafas: fin de sesión limpio, no es un fallo.
            let wasLive = session != nil
            if wasLive { status.endedByDevice = true }
            teardown()
            if wasLive { exitHandler?() }
        case .noEligibleDevice:
            await record(errorClass: "glasses_unavailable", raw: "noEligibleDevice")
            teardown()
            recompute()
        case .other(let message):
            status.lastError = message
            publish()
        }
    }

    private func fail(_ ailment: GlassesAilment, raw: String) async {
        self.ailment = ailment
        await record(errorClass: ailment.errorClass, raw: raw)
        let wasLive = session != nil
        if wasLive { status.endedByDevice = true }
        teardown()
        if wasLive { exitHandler?() }
    }

    /// Teardown limpio SIEMPRE: display.stop() + session.stop() (regla 2).
    public func teardown() {
        generation += 1
        sessionTasks.forEach { $0.cancel() }
        sessionTasks = []
        display?.stop()
        display = nil
        displayStarted = false
        let live = session
        session = nil
        live?.stop()
        releaseWaiters()
        recompute()
    }

    /// Diagnóstico/tests: ¿hay una sesión viva?
    public var hasSession: Bool { session != nil }

    // MARK: - Render

    /// Proyecta una vista: queda como "vista actual" (se re-envía en cada wake).
    public func render(_ view: HUDView) async {
        currentView = view
        if displayStarted { await sendCurrent(view) }
    }

    public func lastRendered() -> HUDView? { currentView }

    private func sendCurrent(_ view: HUDView) async {
        guard let display else { return }
        let handler = actionHandler
        do {
            try await display.send(view) { action in handler?(action) }
        } catch {
            let text = "\(error)"
            // "Superseded by new display request": coalescing normal del SDK.
            if !text.localizedCaseInsensitiveContains("superseded") {
                status.lastError = "HUD send: \(text)"
                publish()
            }
        }
    }

    // MARK: - Cámara

    public func capturePhoto() async throws -> Data {
        guard let session, displayStarted else {
            await record(errorClass: "glasses_unavailable", raw: "capturePhoto sin sesión activa")
            throw GlassesBodyError.unavailable("gafas no conectadas")
        }
        return try await session.capturePhoto()
    }

    // MARK: - RealRegister

    private func record(errorClass: String, raw: String) async {
        guard let realRegister else { return }
        let failure = Failure(
            pattern: PatternKey(toolName: "glasses", argShape: "<body>", errorClass: errorClass, targetResource: nil),
            sessionId: nil, rawError: raw, timestamp: now())
        await realRegister.record(failure)
    }
}
