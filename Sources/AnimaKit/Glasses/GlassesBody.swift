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
    /// Puestas/quitadas (DAT 1.0 DeviceState). Quitárselas NO cierra la sesión
    /// aquí: el teardown lo decide el SDK (hingesClosed / `.stopped`).
    public var donState: GlassesDonState = .unknown
    /// Diagnóstico (Ajustes → Gafas): link, compatibilidad y modelo del device elegido.
    public var link: GlassesLink?
    public var compatibility: GlassesCompatibility?
    public var deviceType: String?
    public var thermal: String?
    /// Último estado de la DeviceSession / Display (diagnóstico).
    public var sessionState: GlassesSessionState?
    public var displayState: GlassesDisplayState?

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
    public nonisolated let diagnostics: GlassesDiagnostics

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
                now: @escaping @Sendable () -> Date = { Date() },
                diagnostics: GlassesDiagnostics = GlassesDiagnostics()) {
        self.runtime = runtime
        self.realRegister = realRegister
        self.now = now
        self.diagnostics = diagnostics
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
            diagnostics.record(.error, "configure: \(error)")
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
        if state != status.registration { diagnostics.record(.registration, state.rawValue) }
        status.registration = state
        if state != .registered { teardown() }
        recompute()
    }

    func onDevices(_ list: [GlassesDeviceSnapshot]) async {
        let previous = device
        device = list.first { $0.link == .connected && $0.supportsDisplay }
            ?? list.first { $0.supportsDisplay }
        if previous?.link != device?.link {
            diagnostics.record(.link, device.map { "\($0.name): \($0.link.rawValue)" } ?? "sin device con display (\(list.count) vistos)")
        }
        if previous?.compatibility != device?.compatibility, let device {
            diagnostics.record(.compat, device.compatibility.rawValue)
        }
        status.deviceName = device?.name
        status.batteryPercent = device?.batteryPercent
        status.donState = device?.donState ?? .unknown
        status.link = device?.link
        status.compatibility = device?.compatibility
        status.deviceType = device?.deviceType
        status.thermal = device?.thermal
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
        diagnostics.record(.hud, "abrir actualización de la app DAT")
        try await runtime.openDATGlassesAppUpdate()
    }

    public func openFirmwareUpdate() async throws {
        diagnostics.record(.hud, "abrir actualización de firmware")
        try await runtime.openFirmwareUpdate()
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
        diagnostics.record(.session, "sesión #\(sessionsCreated) creada (gen \(gen))")
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
            diagnostics.record(.error, "session.start: \(error)")
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
        diagnostics.record(.session, state.rawValue)
        status.sessionState = state
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
            diagnostics.record(.error, "addDisplay: \(error)")
            await record(errorClass: "glasses_unavailable", raw: "addDisplay: \(error)")
            recompute()
        }
    }

    func onDisplayState(_ state: GlassesDisplayState, generation gen: Int) async {
        guard gen == generation else { return }
        diagnostics.record(.display, state.rawValue)
        status.displayState = state
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
        diagnostics.record(.fault, "\(fault)")
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
        if session != nil { diagnostics.record(.session, "teardown (stop)") }
        generation += 1
        sessionTasks.forEach { $0.cancel() }
        sessionTasks = []
        display?.stop()
        display = nil
        displayStarted = false
        status.sessionState = nil
        status.displayState = nil
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
                diagnostics.record(.error, "display.send(\(view.name)): \(text)")
                publish()
            }
        }
    }

    // MARK: - Cámara

    /// Tope de la foto completa (permiso + standalone + reintento + stream). La
    /// pantalla "Tomando la foto…" SIEMPRE sale antes de esto.
    public private(set) var photoDeadline: TimeInterval = 40
    /// Hay una captura del hardware en vuelo (aunque el que esperaba ya se fue).
    public private(set) var photoInFlight = false

    public func setPhotoDeadline(_ seconds: TimeInterval) { photoDeadline = seconds }

    /// Foto POV. Máximo UNA captura en el hardware a la vez (doc DAT: los
    /// resultados no traen id); quien espera recupera el control al vencer el
    /// tope o al cancelar, y la captura vieja se cancela y se suelta sola.
    public func capturePhoto() async throws -> Data {
        guard let session, displayStarted else {
            diagnostics.record(.photo, "rechazada: sin sesión activa")
            await record(errorClass: "glasses_unavailable", raw: "capturePhoto sin sesión activa")
            throw GlassesBodyError.unavailable("gafas no conectadas")
        }
        guard !photoInFlight else {
            diagnostics.record(.photo, "rechazada: ya hay una captura en vuelo")
            throw GlassesPhotoError.busy
        }
        photoInFlight = true
        let started = now()
        diagnostics.record(.photo, "captura iniciada")
        let operation = Task { try await session.capturePhoto() }
        Task { [weak self] in
            let result = await operation.result
            await self?.photoFinished(result.map(\.count), since: started)
        }
        do {
            let data = try await GlassesDeadline.wait(operation, timeout: photoDeadline,
                                                      timeoutError: { GlassesPhotoError.timeout })
            diagnostics.record(.photo, "foto recibida (\(data.count) bytes, \(elapsedMs(since: started)) ms)")
            return data
        } catch is CancellationError {
            diagnostics.record(.photo, "cancelada por el dueño (\(elapsedMs(since: started)) ms)")
            throw CancellationError()
        } catch {
            diagnostics.record(.photo, "falló: \(error) (\(elapsedMs(since: started)) ms)")
            await record(errorClass: "glasses_camera", raw: "\(error)")
            throw error
        }
    }

    private func photoFinished(_ result: Result<Int, Error>, since started: Date) {
        photoInFlight = false
        let outcome: String
        switch result {
        case .success(let bytes): outcome = "ok \(bytes) bytes"
        case .failure(let error): outcome = "\(error)"
        }
        diagnostics.record(.photo, "hardware libre (\(outcome), \(elapsedMs(since: started)) ms)")
    }

    private func elapsedMs(since date: Date) -> Int { Int(now().timeIntervalSince(date) * 1000) }

    // MARK: - RealRegister

    private func record(errorClass: String, raw: String) async {
        guard let realRegister else { return }
        let failure = Failure(
            pattern: PatternKey(toolName: "glasses", argShape: "<body>", errorClass: errorClass, targetResource: nil),
            sessionId: nil, rawError: raw, timestamp: now())
        await realRegister.record(failure)
    }
}
