import Foundation
import Testing
@testable import AnimaKit

// "Hey Meta, start Anima": orquestación pura con dobles del puerto y del cuerpo,
// más la integración contra GlassesActivation + GlassesBody (MockRuntime).

final class MockResponder: VoiceInvocationResponder, @unchecked Sendable {
    let answers = Locked<[(Bool, String?)]>([])
    let delivers: Bool
    init(delivers: Bool = true) { self.delivers = delivers }
    func respond(success: Bool, output: String?) async -> Bool {
        answers.mutate { $0.append((success, output)) }
        return delivers
    }
    var successes: [Bool] { answers.value.map(\.0) }
}

@MainActor
final class MockVoicePort: VoiceInvocationsPort {
    var handler: (@MainActor (VoiceInvocationsPortEvent) -> Void)?
    var starts = 0
    var stops = 0
    func start(_ handler: @escaping @MainActor (VoiceInvocationsPortEvent) -> Void) {
        starts += 1
        self.handler = handler
    }
    func stop() { stops += 1 }
    func emit(_ event: VoiceInvocationsPortEvent) { handler?(event) }
    @discardableResult
    func launch(_ device: String = "g1", responder: MockResponder = MockResponder()) -> MockResponder {
        emit(.invocation(VoiceInvocationRequest(kind: .launchApp, deviceId: device, responder: responder)))
        return responder
    }
}

final class MockLaunchTarget: VoiceLaunchTarget, @unchecked Sendable {
    let outcome: Locked<VoiceLaunchOutcome>
    let launches = Locked(0)
    let homes = Locked(0)
    let delay: UInt64
    init(_ outcome: VoiceLaunchOutcome = .activated, delayMs: UInt64 = 0) {
        self.outcome = Locked(outcome)
        self.delay = delayMs * 1_000_000
    }
    func launchFromVoice(eligibilityTimeout: TimeInterval) async -> VoiceLaunchOutcome {
        launches.mutate { $0 += 1 }
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return outcome.value
    }
    func presentHome() async { homes.mutate { $0 += 1 } }
}

@MainActor
@Suite("Voice invocation — Hey Meta, start Anima")
struct VoiceInvocationTests {

    func make(_ target: MockLaunchTarget? = MockLaunchTarget(), bindTimeout: TimeInterval = 8)
        -> (VoiceInvocationOrchestrator, MockVoicePort, Locked<[VoiceInvocationRecord]>) {
        let port = MockVoicePort()
        let rows = Locked<[VoiceInvocationRecord]>([])
        let orchestrator = VoiceInvocationOrchestrator(port: port, eligibilityTimeout: 0.05, bindTimeout: bindTimeout)
        orchestrator.start()
        if let target { orchestrator.bind(target: target, record: { row in rows.mutate { $0.append(row) } }) }
        return (orchestrator, port, rows)
    }

    @Test func arrancaUnaVezYReportaEstado() async {
        let (orchestrator, port, _) = make()
        orchestrator.start()
        #expect(port.starts == 1)
        #expect(orchestrator.status == .starting)
        port.emit(.listening(deviceIds: []))
        #expect(orchestrator.status == .waitingForGlasses)
        #expect(orchestrator.status.isActive)
        port.emit(.listening(deviceIds: ["g1", "g2"]))
        #expect(orchestrator.status == .listening(devices: 2))
        #expect(orchestrator.status.label == "Activo")
        // Con el stream corriendo, un error transitorio no lo tumba.
        port.emit(.failure(.other("ruido")))
        port.emit(.failure(.deviceUnavailable))
        #expect(orchestrator.status == .listening(devices: 2))
        orchestrator.stop()
        #expect(port.stops == 1)
        orchestrator.start()
        #expect(port.starts == 2)
    }

    @Test func sinSDKNoHayStream() {
        let orchestrator = VoiceInvocationOrchestrator(port: nil)
        orchestrator.start()
        orchestrator.stop()
        #expect(orchestrator.status == .unavailable)
        #expect(orchestrator.status.label == "No disponible en esta build")
        #expect(!orchestrator.status.isActive)
    }

    @Test func erroresDelStreamSeMapeanAlEstado() async {
        let (orchestrator, port, _) = make()
        port.emit(.failure(.deviceUnavailable))
        #expect(orchestrator.status == .waitingForGlasses)
        port.emit(.listening(deviceIds: []))
        port.emit(.failure(.notPermitted))
        #expect(orchestrator.status == .needsPortalPermission)
        #expect(orchestrator.status.label.contains("portal de Meta"))
        #expect(orchestrator.status.label.contains("Voice Invocation"))
        port.emit(.failure(.other("channelError")))
        #expect(orchestrator.status == .failed("channelError"))
        #expect(orchestrator.status.label == "Inactivo · channelError")
        #expect(VoiceInvocationsStatus.starting.label == "Iniciando…")
        #expect(VoiceInvocationsStatus.waitingForGlasses.label.hasPrefix("Activo"))
    }

    @Test func streamDeEstado() async {
        let (orchestrator, port, _) = make()
        let stream = orchestrator.statusUpdates()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .starting)
        port.emit(.listening(deviceIds: ["g1"]))
        #expect(await iterator.next() == .listening(devices: 1))
    }

    @Test func launchAppActivaAckSuccessYHome() async {
        let target = MockLaunchTarget(.activated)
        let (orchestrator, port, rows) = make(target)
        let responder = port.launch()
        #expect(await eventually { target.homes.value == 1 })
        #expect(responder.successes == [true])
        #expect(target.launches.value == 1)
        let phases = rows.value.map(\.phase)
        #expect(phases == [.received, .ack, .result])
        #expect(rows.value[1].outcome == "success")
        #expect(rows.value[1].delivered == true)
        #expect(rows.value[2].outcome == "activated")
        #expect(rows.value.allSatisfy { $0.kind == .launchApp && $0.deviceId == "g1" })
        #expect((rows.value[2].latencyMs ?? -1) >= 0)
        withExtendedLifetime(orchestrator) {}
    }

    @Test func sesionYaActivaEsIdempotente() async {
        let target = MockLaunchTarget(.alreadyActive)
        let (orchestrator, port, rows) = make(target)
        let responder = port.launch()
        #expect(await eventually { rows.value.count == 3 })
        #expect(responder.successes == [true])
        #expect(rows.value[2].outcome == "alreadyActive")
        #expect(target.homes.value == 0)   // no se toca la vista de una conversación viva
        withExtendedLifetime(orchestrator) {}
    }

    @Test func activacionFallidaEsAckFailure() async {
        let target = MockLaunchTarget(.failed("gafas lejos"))
        let (orchestrator, port, rows) = make(target)
        let responder = port.launch(responder: MockResponder(delivers: false))
        #expect(await eventually { rows.value.count == 3 })
        #expect(responder.successes == [false])
        #expect(responder.answers.value.first?.1 == "gafas lejos")
        #expect(rows.value[1].outcome == "failure")
        #expect(rows.value[1].delivered == false)
        #expect(rows.value[2].outcome == "failed")
        #expect(rows.value[2].detail == "gafas lejos")
        #expect(target.homes.value == 0)
        #expect(!VoiceLaunchOutcome.failed("x").succeeded)
        #expect(VoiceLaunchOutcome.alreadyActive.succeeded)
        withExtendedLifetime(orchestrator) {}
    }

    @Test func invocacionNoSoportadaSeRespondeFailure() async {
        let target = MockLaunchTarget()
        let (orchestrator, port, rows) = make(target)
        let responder = MockResponder()
        port.emit(.invocation(VoiceInvocationRequest(kind: .unsupported, deviceId: "g1", responder: responder)))
        #expect(await eventually { rows.value.count == 3 })
        #expect(responder.successes == [false])
        #expect(rows.value[2].outcome == "unsupported")
        #expect(target.launches.value == 0)
        withExtendedLifetime(orchestrator) {}
    }

    @Test func invocacionesSimultaneasCompartenUnaActivacion() async {
        let target = MockLaunchTarget(.activated, delayMs: 30)
        let (orchestrator, port, rows) = make(target)
        let a = port.launch()
        let b = port.launch()
        #expect(await eventually { rows.value.count == 6 })
        #expect(target.launches.value == 1)
        #expect(a.successes == [true])
        #expect(b.successes == [true])
        // Pasada la ráfaga, una invocación nueva vuelve a consultar al cuerpo.
        target.outcome.mutate { $0 = .alreadyActive }
        port.launch()
        #expect(await eventually { rows.value.count == 9 })
        #expect(target.launches.value == 2)
        withExtendedLifetime(orchestrator) {}
    }

    @Test func coldLaunchEncolaHastaElBind() async {
        let (orchestrator, port, _) = make(nil)
        let responder = port.launch()
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(responder.answers.value.isEmpty)   // sin cuerpo aún: no se responde a ciegas
        let target = MockLaunchTarget(.activated)
        let rows = Locked<[VoiceInvocationRecord]>([])
        orchestrator.bind(target: target, record: { row in rows.mutate { $0.append(row) } })
        #expect(await eventually { rows.value.count == 3 })
        #expect(rows.value.first?.phase == .received)   // el buffer previo al bind se vuelca
        #expect(responder.successes == [true])
        #expect(target.homes.value == 1)
    }

    @Test func coldLaunchSinCuerpoExpiraConFailure() async {
        let (orchestrator, port, _) = make(nil, bindTimeout: 0.05)
        let responder = port.launch()
        port.launch(responder: responder)
        #expect(await eventually { responder.answers.value.count == 2 })
        #expect(responder.successes == [false, false])
        #expect(responder.answers.value.first?.1 == "la app no terminó de arrancar")
        // Bind tardío: nada pendiente, la telemetría acumulada se vuelca.
        let rows = Locked<[VoiceInvocationRecord]>([])
        orchestrator.bind(target: MockLaunchTarget(), record: { row in rows.mutate { $0.append(row) } })
        #expect(rows.value.filter { $0.phase == .result }.map(\.outcome) == ["timeout", "timeout"])
    }

    @Test func telemetriaPersisteEnGRDB() throws {
        let telemetry = Telemetry(queue: try AnimaDatabase.temporary())
        let rows = [
            VoiceInvocationRecord(phase: .received, kind: .launchApp, deviceId: "g1"),
            VoiceInvocationRecord(phase: .ack, kind: .launchApp, deviceId: "g1", outcome: "success",
                                  delivered: true, latencyMs: 12.5),
            VoiceInvocationRecord(phase: .result, kind: .unsupported, deviceId: "g1", outcome: "unsupported",
                                  delivered: nil, detail: "x", latencyMs: 13),
        ]
        for row in rows { try telemetry.recordVoiceInvocation(row) }
        #expect(try telemetry.voiceInvocations() == rows)
    }

    // MARK: - Integración con el cuerpo real (GlassesActivation + GlassesBody)

    @Test func cuerpoDormidoSeEnciendePorVozYMuestraHome() async throws {
        let runtime = MockRuntime()
        let body = await readyBody(runtime)
        let activation = GlassesActivation(body: body)
        await activation.userExited()   // el dueño había salido: la voz es interacción explícita
        let (orchestrator, port, rows) = make(nil)
        orchestrator.bind(target: activation, record: { row in rows.mutate { $0.append(row) } })
        let first = port.launch()
        #expect(await eventually { first.successes == [true] })
        #expect(await activation.isSuppressed == false)
        #expect(await eventually { await body.currentStatus().body == .active })
        #expect(await eventually { await body.lastRendered()?.name == HUDRenderer.render(.home(status: nil)).name })
        #expect(await eventually { runtime.lastSession?.display.sent.value.isEmpty == false })
        // Segunda invocación con sesión viva: success sin abrir otra sesión.
        let second = port.launch()
        #expect(await eventually { second.successes == [true] })
        #expect(await body.sessionsCreated == 1)
        #expect(await eventually { rows.value.last?.outcome == "alreadyActive" })
    }

    @Test func coldLaunchEsperaAQueElDATReporteElDevice() async throws {
        let runtime = MockRuntime()
        let body = GlassesBody(runtime: runtime)
        await body.start()   // registrado pero sin devices todavía
        let activation = GlassesActivation(body: body)
        let outcome = Task { await activation.launchFromVoice(eligibilityTimeout: 2) }
        try await Task.sleep(nanoseconds: 30_000_000)
        runtime.setDevices([MockRuntime.display])
        #expect(await outcome.value == .activated)
        await activation.presentHome()
        #expect(await body.currentStatus().body == .active)
        #expect(await body.lastRendered() != nil)
    }

    @Test func sinGafasLaVozFallaTrasElTimeout() async throws {
        let runtime = MockRuntime()
        let body = GlassesBody(runtime: runtime)
        await body.start()
        let activation = GlassesActivation(body: body)
        let outcome = await activation.launchFromVoice(eligibilityTimeout: 0.05)
        #expect(outcome == .failed("gafas lejos"))
        #expect(await body.sessionsCreated == 0)
    }

    @Test func fallaAlAbrirLaSesionEsFailure() async throws {
        let runtime = MockRuntime()
        let body = await readyBody(runtime)
        let activation = GlassesActivation(body: body)
        runtime.makeError.mutate { $0 = MockError("claimed") }
        let outcome = await activation.launchFromVoice(eligibilityTimeout: 0.05)
        guard case .failed(let why) = outcome else { Issue.record("esperaba failure"); return }
        #expect(why.contains("sesión"))
    }

    @Test func homeNoPisaUnaVistaExistenteNiEsperaSinDisplay() async throws {
        let runtime = MockRuntime()
        runtime.nextSession.mutate { $0 = { MockSession(display: MockDisplay(autoStart: false)) } }
        let body = await readyBody(runtime)
        let activation = GlassesActivation(body: body)
        #expect(await activation.launchFromVoice(eligibilityTimeout: 0.05) == .activated)
        let custom = HUDRenderer.render(.home(status: "custom"))
        await body.render(custom)
        // Sin display .started, presentHome no renderiza (timeout del body).
        let waiter = Task { await activation.presentHome() }
        try await Task.sleep(nanoseconds: 20_000_000)
        runtime.lastSession?.display.wake()
        await waiter.value
        #expect(await body.lastRendered() == custom)
    }
}
