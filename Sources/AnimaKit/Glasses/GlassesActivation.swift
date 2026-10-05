// GlassesActivation.swift — CUÁNDO se enciende el cuerpo. `ensureActive()` es la
// única vía de arranque (doc 05 §3.1); esta política decide llamarla:
//   · al volverse elegible (registrado + conectado + compatible) con la app en
//     primer plano → activa y proyecta la card de bienvenida "anima 👋" (G0);
//   · tras un back físico / doff el dueño SALIÓ: no se re-abre sola (sería
//     pelearle el gesto) hasta la próxima interacción explícita — volver a
//     primer plano o "Mostrar en las gafas" en Ajustes/Mind sheet.
//   · re-entrada (campo #6): el back físico TERMINA la sesión siempre y nunca
//     llega a la app. El DAT SDK exige que el dueño inicie la sesión de display
//     ("Users must explicitly initiate a display session"): NO se puede
//     reactivar sola desde background. Por eso, si la salida ocurre con la app
//     en background (teléfono en el bolsillo), se avisa con una notificación
//     local "Anima sigue aquí" cuyo deep link (anima://glasses) foregroundea y
//     reactiva — esa interacción explícita es la que el SDK pide.
//   · don-wake (DAT 1.0 DonState): PONERSE las gafas (transición → .donned) es
//     interacción explícita: limpia la supresión y, en primer plano, reactiva la
//     sesión y vuelve a proyectar la Home. En background NO se pelea al SDK:
//     queda armado y se consume al volver a primer plano con las gafas puestas.
//     Quitárselas (doff) solo desarma: el teardown lo hace el SDK. Respeta el
//     ajuste "Despertar al ponértelas" (deshabilitado = sin don-wake).

import Foundation

/// Telemetría de eventos del cuerpo-gafas fuera del turno (tabla glasses_event_telemetry).
public struct GlassesEventRecord: Sendable, Equatable {
    public static let donWake = "don_wake"
    public var event: String
    /// don_wake: activated | alreadyActive | deferred | failed.
    public var outcome: String
    public var detail: String?

    public init(event: String, outcome: String, detail: String? = nil) {
        self.event = event
        self.outcome = outcome
        self.detail = detail
    }
}

public actor GlassesActivation {
    private let body: GlassesBody
    private var suppressed = false
    private var foreground = true
    private var task: Task<Void, Never>?
    /// La vista inicial al activar (G0: bienvenida). La superficie la reemplaza.
    private let initialView: @Sendable (GlassesStatus) -> HUDView
    /// Aviso de re-entrada (notificación local) tras una salida en background.
    private let reentry: (@Sendable () async -> Void)?
    private let events: (@Sendable (GlassesEventRecord) -> Void)?

    // Don-wake.
    private var donWakeEnabled = true
    private var lastDon: GlassesDonState = .unknown
    /// Se puso las gafas y aún no se consumió (background / device reconectando).
    private var donPending = false
    private var donDeferred = false

    public init(body: GlassesBody,
                initialView: @escaping @Sendable (GlassesStatus) -> HUDView = { _ in
                    HUDRenderer.render(.home(status: nil))
                },
                reentry: (@Sendable () async -> Void)? = nil,
                events: (@Sendable (GlassesEventRecord) -> Void)? = nil) {
        self.body = body
        self.initialView = initialView
        self.reentry = reentry
        self.events = events
    }

    /// Empieza a observar el cuerpo. Idempotente.
    public func start() async {
        guard task == nil else { return }
        let stream = await body.statusUpdates()
        task = Task { [weak self] in
            for await status in stream { await self?.onStatus(status) }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    func onStatus(_ status: GlassesStatus) async {
        trackDon(status.donState)
        if donPending {
            await consumeDonWake(status)
            return
        }
        guard status.body == .dormant, !status.endedByDevice, foreground, !suppressed else { return }
        await activate()
    }

    // MARK: - Don-wake

    /// Ajuste del dueño "Despertar al ponértelas" (default: sí).
    public func setDonWakeEnabled(_ enabled: Bool) {
        donWakeEnabled = enabled
        if !enabled { disarm() }
    }

    public var isDonWakeEnabled: Bool { donWakeEnabled }
    /// Tests/diagnóstico: hay un don esperando a consumirse.
    public var isDonWakeArmed: Bool { donPending }

    /// Solo cuenta la transición doffed → donned. `.unknown` (device perdido al
    /// reconectar) no rompe la memoria del último estado conocido, y el primer
    /// reporte al arrancar no es un "don" (lo cubre la activación normal).
    private func trackDon(_ don: GlassesDonState) {
        guard don != .unknown, don != lastDon else { return }
        let previous = lastDon
        lastDon = don
        switch don {
        case .donned:
            guard previous == .doffed, donWakeEnabled else { return }
            donPending = true
            donDeferred = false
        case .doffed, .unknown:
            disarm()   // doff no mata la sesión: solo desarma el don pendiente
        }
    }

    private func disarm() {
        donPending = false
        donDeferred = false
    }

    private func consumeDonWake(_ status: GlassesStatus) async {
        guard foreground else {
            // El SDK no permite iniciar la sesión desde background: queda armado.
            if !donDeferred {
                donDeferred = true
                events?(GlassesEventRecord(event: GlassesEventRecord.donWake, outcome: "deferred"))
            }
            return
        }
        let live = await body.hasSession
        guard donPending else { return }   // otro status lo consumió durante el await
        if live {
            let deferred = donDeferred
            disarm()
            events?(GlassesEventRecord(event: GlassesEventRecord.donWake, outcome: "alreadyActive",
                                       detail: deferred ? "foreground" : nil))
            return
        }
        // Device aún no elegible (reconectando tras el doff): sigue armado.
        guard status.body == .dormant else { return }
        let deferred = donDeferred
        disarm()
        suppressed = false
        let ok = await activate()
        events?(GlassesEventRecord(event: GlassesEventRecord.donWake, outcome: ok ? "activated" : "failed",
                                   detail: deferred ? "foreground" : nil))
    }

    /// Interacción explícita del dueño ("Mostrar en las gafas").
    public func userRequested() async {
        suppressed = false
        await activate()
    }

    /// El dueño salió (back físico / se quitó las gafas). En background, se
    /// le deja el camino de vuelta (notificación → foreground → reactiva).
    public func userExited() async {
        suppressed = true
        if !foreground { await reentry?() }
    }

    public func setForeground(_ isForeground: Bool) async {
        foreground = isForeground
        guard isForeground else { return }
        suppressed = false
        let status = await body.currentStatus()
        if donPending, status.donState == .donned {
            await consumeDonWake(status)   // se las puso con la app en background
            return
        }
        if status.body == .dormant { await activate() }   // interacción explícita
    }

    @discardableResult
    func activate() async -> Bool {
        do {
            try await body.ensureActive()
        } catch {
            return false
        }
        if await body.lastRendered() == nil {
            await body.render(initialView(await body.currentStatus()))
        }
        return true
    }

    public var isSuppressed: Bool { suppressed }
}

// MARK: - "Hey Meta, start Anima" (VoiceInvocationOrchestrator)

extension GlassesActivation: VoiceLaunchTarget {
    /// Invocación por voz = interacción explícita: limpia la supresión. Idempotente
    /// con sesión viva; en cold-launch espera (acotado) a que el DAT reporte el device.
    public func launchFromVoice(eligibilityTimeout: TimeInterval) async -> VoiceLaunchOutcome {
        suppressed = false
        if await body.hasSession { return .alreadyActive }
        guard await waitUntilEligible(timeout: eligibilityTimeout) else {
            return .failed(await body.currentStatus().bodyLabel)
        }
        do {
            try await body.ensureActive()
            return .activated
        } catch {
            return .failed("\(error)")
        }
    }

    public func presentHome() async {
        guard await body.waitUntilActive() else { return }
        if await body.lastRendered() == nil {
            await body.render(initialView(await body.currentStatus()))
        }
    }

    func waitUntilEligible(timeout: TimeInterval) async -> Bool {
        if await body.isEligible { return true }
        let updates = await body.statusUpdates()
        let body = self.body
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in updates where await body.isEligible { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
