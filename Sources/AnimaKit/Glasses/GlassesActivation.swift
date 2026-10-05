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

import Foundation

public actor GlassesActivation {
    private let body: GlassesBody
    private var suppressed = false
    private var foreground = true
    private var task: Task<Void, Never>?
    /// La vista inicial al activar (G0: bienvenida). La superficie la reemplaza.
    private let initialView: @Sendable (GlassesStatus) -> HUDView
    /// Aviso de re-entrada (notificación local) tras una salida en background.
    private let reentry: (@Sendable () async -> Void)?

    public init(body: GlassesBody,
                initialView: @escaping @Sendable (GlassesStatus) -> HUDView = { _ in
                    HUDRenderer.render(.home(status: nil))
                },
                reentry: (@Sendable () async -> Void)? = nil) {
        self.body = body
        self.initialView = initialView
        self.reentry = reentry
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
        guard status.body == .dormant, !status.endedByDevice, foreground, !suppressed else { return }
        await activate()
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
        if await body.currentStatus().body == .dormant { await activate() }   // interacción explícita
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
