import Foundation
import Testing
@testable import AnimaKit

@Suite("Don-wake — ponerse las gafas reactiva la sesión (DAT 1.0 DonState)")
struct GlassesDonWakeTests {

    static func device(_ don: GlassesDonState, link: GlassesLink = .connected) -> GlassesDeviceSnapshot {
        var snapshot = MockRuntime.display
        snapshot.donState = don
        snapshot.link = link
        return snapshot
    }

    struct Rig {
        let runtime: MockRuntime
        let body: GlassesBody
        let activation: GlassesActivation
        let events: Locked<[GlassesEventRecord]>

        var donWakes: [GlassesEventRecord] { events.value.filter { $0.event == GlassesEventRecord.donWake } }
    }

    /// Cuerpo + activación cableados como en la app (onExit → userExited), con
    /// las gafas puestas y la sesión ya activa una vez en esta ejecución.
    static func activeRig() async -> Rig {
        let runtime = MockRuntime()
        let body = GlassesBody(runtime: runtime)
        let events = Locked<[GlassesEventRecord]>([])
        let activation = GlassesActivation(body: body, events: { row in events.mutate { $0.append(row) } })
        await body.setHandlers(onAction: nil, onExit: { Task { await activation.userExited() } })
        await body.start()
        await activation.start()
        runtime.setDevices([device(.donned)])
        _ = await eventually { await body.currentStatus().body == .active }
        return Rig(runtime: runtime, body: body, activation: activation, events: events)
    }

    /// Se las quita y el SDK termina la sesión por su cuenta (hingesClosed/stopped).
    static func doffAndSDKTeardown(_ rig: Rig) async {
        rig.runtime.setDevices([device(.doffed)])
        _ = await eventually { await rig.body.currentStatus().donState == .doffed }
        rig.runtime.lastSession?.endFromDevice()
        _ = await eventually { await rig.body.currentStatus().body == .dormant }
        _ = await eventually { await rig.activation.isSuppressed }
    }

    @Test func donEnPrimerPlanoReactivaYMuestraLaHome() async throws {
        let rig = await Self.activeRig()
        #expect(await rig.body.currentStatus().body == .active)
        await Self.doffAndSDKTeardown(rig)
        #expect(rig.runtime.sessions.value.count == 1)

        rig.runtime.setDevices([Self.device(.donned)])
        #expect(await eventually { await rig.body.currentStatus().body == .active })
        #expect(rig.runtime.sessions.value.count == 2)
        #expect(rig.runtime.liveSessions == 1)
        #expect(await rig.activation.isSuppressed == false)
        let display = try #require(rig.runtime.lastSession?.display)
        #expect(await eventually { display.sent.value.last?.name == "home" })
        #expect(await eventually { rig.donWakes.count == 1 })
        #expect(rig.donWakes.first?.outcome == "activated")
        #expect(rig.donWakes.first?.detail == nil)
        await rig.activation.stop()
    }

    @Test func doffNoMataLaSesion() async throws {
        let rig = await Self.activeRig()
        let session = try #require(rig.runtime.lastSession)
        rig.runtime.setDevices([Self.device(.doffed)])
        #expect(await eventually { await rig.body.currentStatus().donState == .doffed })
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(session.stopped.value == 0, "doff deja el teardown al SDK")
        #expect(await rig.body.hasSession)
        #expect(await rig.body.currentStatus().body == .active)
        #expect(await rig.activation.isDonWakeArmed == false)
        await rig.activation.stop()
    }

    @Test func donConSesionVivaEsIdempotente() async throws {
        let rig = await Self.activeRig()
        rig.runtime.setDevices([Self.device(.doffed)])
        #expect(await eventually { await rig.body.currentStatus().donState == .doffed })
        rig.runtime.setDevices([Self.device(.donned)])   // se las vuelve a poner sin que el SDK cerrara
        #expect(await eventually { rig.donWakes.count == 1 })
        #expect(rig.donWakes.first?.outcome == "alreadyActive")
        #expect(rig.runtime.sessions.value.count == 1)
        #expect(rig.runtime.liveSessions == 1)
        await rig.activation.stop()
    }

    @Test func donEnBackgroundQuedaArmadoYActivaAlVolver() async throws {
        let rig = await Self.activeRig()
        await rig.activation.setForeground(false)
        await Self.doffAndSDKTeardown(rig)

        rig.runtime.setDevices([Self.device(.donned)])
        #expect(await eventually { await rig.activation.isDonWakeArmed })
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(await rig.body.hasSession == false, "el SDK no deja iniciar sesión desde background")
        #expect(rig.runtime.sessions.value.count == 1)
        #expect(rig.donWakes.map(\.outcome) == ["deferred"])
        // Más eventos de estado (batería…) no duplican el "deferred".
        var again = Self.device(.donned)
        again.batteryPercent = 80
        rig.runtime.setDevices([again])
        #expect(await eventually { await rig.body.currentStatus().batteryPercent == 80 })
        #expect(rig.donWakes.count == 1)

        await rig.activation.setForeground(true)
        #expect(await eventually { await rig.body.currentStatus().body == .active })
        #expect(await rig.activation.isDonWakeArmed == false)
        #expect(rig.donWakes.map(\.outcome) == ["deferred", "activated"])
        #expect(rig.donWakes.last?.detail == "foreground")
        await rig.activation.stop()
    }

    @Test func doffEnBackgroundDesarma() async throws {
        let rig = await Self.activeRig()
        await rig.activation.setForeground(false)
        await Self.doffAndSDKTeardown(rig)
        rig.runtime.setDevices([Self.device(.donned)])
        #expect(await eventually { await rig.activation.isDonWakeArmed })
        rig.runtime.setDevices([Self.device(.doffed)])
        #expect(await eventually { await rig.activation.isDonWakeArmed == false })
        await rig.activation.setForeground(true)   // primer plano normal: activa, pero no es don-wake
        #expect(await eventually { await rig.body.currentStatus().body == .active })
        #expect(rig.donWakes.map(\.outcome) == ["deferred"])
        await rig.activation.stop()
    }

    @Test func deshabilitadoRespetaLaSalidaDelDueno() async throws {
        let rig = await Self.activeRig()
        await rig.activation.setDonWakeEnabled(false)
        #expect(await rig.activation.isDonWakeEnabled == false)
        await Self.doffAndSDKTeardown(rig)
        rig.runtime.setDevices([Self.device(.donned)])
        #expect(await eventually { await rig.body.currentStatus().donState == .donned })
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(await rig.body.hasSession == false)
        #expect(await rig.activation.isSuppressed)
        #expect(rig.donWakes.isEmpty)

        // Rehabilitado: el próximo ciclo doff → don sí despierta.
        await rig.activation.setDonWakeEnabled(true)
        rig.runtime.setDevices([Self.device(.doffed)])
        #expect(await eventually { await rig.body.currentStatus().donState == .doffed })
        rig.runtime.setDevices([Self.device(.donned)])
        #expect(await eventually { await rig.body.currentStatus().body == .active })
        #expect(rig.donWakes.map(\.outcome) == ["activated"])
        await rig.activation.stop()
    }

    @Test func donMientrasReconectaEsperaAQueSeaElegible() async throws {
        let rig = await Self.activeRig()
        rig.runtime.setDevices([Self.device(.doffed, link: .disconnected)])   // doff + link caído
        #expect(await eventually { await rig.body.hasSession == false })
        rig.runtime.setDevices([])   // el device desaparece: donState .unknown no borra la memoria
        #expect(await eventually { await rig.body.currentStatus().donState == .unknown })
        rig.runtime.setDevices([Self.device(.donned, link: .connecting)])
        #expect(await eventually { await rig.activation.isDonWakeArmed })
        #expect(await rig.body.hasSession == false)
        rig.runtime.setDevices([Self.device(.donned)])
        #expect(await eventually { await rig.body.currentStatus().body == .active })
        #expect(await eventually { rig.donWakes.map(\.outcome) == ["activated"] })
        await rig.activation.stop()
    }

    @Test func elPrimerReporteAlArrancarNoEsUnDon() async throws {
        let rig = await Self.activeRig()   // arranca ya con .donned
        #expect(rig.donWakes.isEmpty)
        #expect(rig.runtime.sessions.value.count == 1)
        await rig.activation.stop()
    }

    @Test func donSinDeviceElegibleNoActivaYFallaSinRomper() async throws {
        let runtime = MockRuntime()
        let body = GlassesBody(runtime: runtime)
        let events = Locked<[GlassesEventRecord]>([])
        let activation = GlassesActivation(body: body, events: { row in events.mutate { $0.append(row) } })
        await body.start()
        // No elegible para ensureActive pero el status dice dormant: makeSession falla.
        runtime.makeError.mutate { $0 = MockError("sin selector") }
        await activation.start()
        runtime.setDevices([Self.device(.doffed)])
        #expect(await eventually { await body.currentStatus().donState == .doffed })
        runtime.setDevices([Self.device(.donned)])
        #expect(await eventually { events.value.contains { $0.outcome == "failed" } })
        #expect(await body.hasSession == false)
        await activation.stop()
    }

    @Test func telemetriaPersisteElEvento() throws {
        let telemetry = Telemetry(queue: try AnimaDatabase.temporary())
        try telemetry.recordGlassesEvent(GlassesEventRecord(event: GlassesEventRecord.donWake, outcome: "deferred"))
        try telemetry.recordGlassesEvent(GlassesEventRecord(event: GlassesEventRecord.donWake, outcome: "activated",
                                                            detail: "foreground"))
        let rows = try telemetry.glassesEvents()
        #expect(rows.map(\.outcome) == ["deferred", "activated"])
        #expect(rows.last?.detail == "foreground")
        #expect(rows.allSatisfy { $0.event == "don_wake" })
    }
}
