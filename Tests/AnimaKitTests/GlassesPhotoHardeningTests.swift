import Foundation
import Testing
@testable import AnimaKit

// "Tomando la foto…" SIEMPRE sale (éxito, error claro o cancelar),
// la continuation se resuelve EXACTAMENTE una vez y nunca hay dos capturas en
// el hardware a la vez.

/// Una "captura" que ignora la cancelación (el peor caso del SDK).
func stubbornCapture(_ seconds: TimeInterval, result: Data = Data([0xFF])) -> @Sendable () async throws -> Data {
    {
        await Task.detached { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }.value
        return result
    }
}

@Suite("Campo — primitivas de la foto (once, deadline, permiso)")
struct GlassesOnceDeadlineTests {

    @Test func onceEntregaSoloElPrimerValor() {
        let once = GlassesOnce<Int>()
        let got = Locked<[Int]>([])
        once.set { v in got.mutate { $0.append(v) } }
        #expect(!once.isResolved)
        #expect(once.fire(1))
        #expect(!once.fire(2))
        #expect(got.value == [1])
        #expect(once.isResolved)
    }

    @Test func onceAntesDelHandlerQuedaPendiente() {
        let once = GlassesOnce<String>()
        #expect(once.fire("cancel"))
        #expect(!once.fire("tarde"))
        let got = Locked<[String]>([])
        once.set { v in got.mutate { $0.append(v) } }
        #expect(got.value == ["cancel"])
        once.set { v in got.mutate { $0.append("otra \(v)") } }
        #expect(got.value == ["cancel"])
    }

    @Test func onceBajoConcurrenciaResuelveUnaVez() async {
        let once = GlassesOnce<Int>()
        let calls = Locked(0)
        once.set { _ in calls.mutate { $0 += 1 } }
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 { group.addTask { once.fire(i) } }
        }
        #expect(calls.value == 1)
    }

    @Test func flagSetOnceSoloParaElPrimero() {
        let flag = GlassesFlag()
        #expect(!flag.isSet)
        #expect(flag.setOnce())
        #expect(!flag.setOnce())
        let other = GlassesFlag()
        other.set()
        #expect(other.isSet)
        #expect(!other.setOnce())
    }

    @Test func deadlineDevuelveElValor() async throws {
        let value = try await GlassesDeadline.run(timeout: 5, timeoutError: { GlassesPhotoError.timeout }) { 42 }
        #expect(value == 42)
        await #expect(throws: MockError.self) {
            _ = try await GlassesDeadline.run(timeout: 5, timeoutError: { GlassesPhotoError.timeout }) { () -> Int in
                throw MockError("x")
            }
        }
    }

    @Test func deadlineVenceAunqueLaTareaIgnoreLaCancelacion() async {
        // La captura terca dura 60 s y el runner de CI puede congelarse varios
        // segundos: el tope solo prueba que NO se esperó a la tarea.
        let started = Date()
        let capture = stubbornCapture(60)
        await #expect(throws: GlassesPhotoError.timeout) {
            _ = try await GlassesDeadline.run(timeout: 0.1, timeoutError: { GlassesPhotoError.timeout }, capture)
        }
        #expect(Date().timeIntervalSince(started) < 30)
    }

    @Test func cancelarAlQueEsperaDevuelveElControlYCancelaLaTarea() async {
        let cancelled = Locked(false)
        let task = Task<Int, Error> {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { cancelled.mutate { $0 = true }; throw error }
            return 1
        }
        let waiter = Task { try await GlassesDeadline.wait(task, timeout: 10, timeoutError: { GlassesPhotoError.timeout }) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiter.value }
        #expect(await eventually { cancelled.value })
    }

    @Test func permisoYaConcedidoNoAbreMetaAI() async throws {
        let requests = Locked(0)
        let prompts = Locked(0)
        try await GlassesCameraPermission.ensure(check: { true }, request: { requests.mutate { $0 += 1 }; return true },
                                                 onPrompt: { prompts.mutate { $0 += 1 } })
        #expect(requests.value == 0)
        #expect(prompts.value == 0)
    }

    @Test func permisoPedidoYConcedido() async throws {
        let log = Locked<[String]>([])
        let prompts = Locked(0)
        try await GlassesCameraPermission.ensure(check: { false }, request: { true },
                                                 onPrompt: { prompts.mutate { $0 += 1 } },
                                                 log: { m in log.mutate { $0.append(m) } })
        #expect(log.value == ["permiso de cámara: pidiendo a Meta AI", "permiso de cámara: concedido"])
        #expect(prompts.value == 1)
    }

    @Test func metaAISinRespuestaDejaUnaSolaCausa() async {
        let log = Locked<[String]>([])
        let error = GlassesPhotoError.permissionDenied(GlassesCameraPermission.noResponse)
        await #expect(throws: error) {
            try await GlassesCameraPermission.ensure(check: { false }, request: stubbornBool(3), timeout: 0.1,
                                                     log: { m in log.mutate { $0.append(m) } })
        }
        #expect(error.description == "permiso de cámara denegado en Meta AI (Meta AI no respondió)")
        #expect(log.value.last == "permiso de cámara: Meta AI no respondió")
        #expect(HUDPhoto.message(for: error) == "Meta AI no respondió a tiempo. Aprueba la cámara y reintenta.")
    }

    @Test func alVolverDeMetaAISeRechequea() async throws {
        // request lanza (p. ej. requestTimeout) pero el dueño sí concedió en Meta AI.
        let checks = Locked(0)
        try await GlassesCameraPermission.ensure(check: { checks.mutate { $0 += 1 }; return checks.value > 1 },
                                                 request: { throw MockError("requestTimeout") })
        #expect(checks.value == 2)
        // Meta AI nunca responde: el tope vence y el re-chequeo decide.
        let late = Locked(0)
        try await GlassesCameraPermission.ensure(check: { late.mutate { $0 += 1 }; return late.value > 1 },
                                                 request: stubbornBool(3), timeout: 0.1)
    }

    @Test func permisoDenegadoEsUnErrorClaro() async {
        await #expect(throws: GlassesPhotoError.permissionDenied("denegado")) {
            try await GlassesCameraPermission.ensure(check: { false }, request: { false })
        }
        await #expect(throws: GlassesPhotoError.permissionDenied("x")) {
            try await GlassesCameraPermission.ensure(check: { false }, request: { throw MockError("x") })
        }
        let message = HUDPhoto.message(for: GlassesPhotoError.permissionDenied(nil))
        #expect(message?.hasPrefix("Permiso de cámara denegado en Meta AI") == true)
    }

    @Test func permisoCanceladoSePropaga() async {
        let task = Task {
            try await GlassesCameraPermission.ensure(check: { false }, request: {
                try await Task.sleep(nanoseconds: 5_000_000_000); return true
            })
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    func stubbornBool(_ seconds: TimeInterval) -> @Sendable () async throws -> Bool {
        {
            await Task.detached { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }.value
            return false
        }
    }
}

@Suite("Campo — mensajes de la foto en el HUD")
struct HUDPhotoMessageTests {
    @Test func cadaErrorTieneSuTextoFijoSinTokensDelSDK() {
        #expect(HUDPhoto.message(for: CancellationError()) == nil)
        #expect(HUDPhoto.message(for: GlassesPhotoError.setupFailed("timeout")) == "La cámara no respondió a tiempo. Reintenta.")
        #expect(HUDPhoto.message(for: GlassesPhotoError.setupFailed("stopped")) == "La cámara no arrancó. Reintenta.")
        #expect(HUDPhoto.message(for: GlassesPhotoError.unsupported("notReady")) == "Las gafas no dejaron tomar la foto. Reintenta.")
        #expect(HUDPhoto.message(for: GlassesPhotoError.failed("busy")) == "La foto falló. Reintenta.")
        #expect(HUDPhoto.message(for: GlassesPhotoError.timeout) == "La foto no llegó a tiempo. Reintenta.")
        #expect(HUDPhoto.message(for: GlassesPhotoError.busy)?.hasPrefix("Ya hay una foto en curso") == true)
        #expect(HUDPhoto.message(for: GlassesPhotoError.unavailable("nil")) == "La cámara de las gafas no está disponible.")
        #expect(HUDPhoto.message(for: GlassesBodyError.unavailable("x")) == "Las gafas no están conectadas.")
        #expect(HUDPhoto.message(for: MockError("raro")) == HUDPhoto.failure)
        let raw: [GlassesPhotoError] = [.setupFailed("stopped"), .setupFailed("timeout"), .unsupported("notReady"),
                                        .failed(GlassesStandaloneStop.stoppedAfterCapture), .permissionDenied("denegado")]
        for error in raw {
            let message = HUDPhoto.message(for: error) ?? ""
            #expect(!message.contains("("), "token crudo en el HUD: \(message)")
        }
        // El detalle crudo sigue en la descripción (diagnóstico).
        #expect(GlassesPhotoError.unsupported("notReady").description.contains("notReady"))
        for error in [GlassesPhotoError.permissionDenied("x"), .timeout, .busy, .unavailable("y")] {
            #expect(!error.description.isEmpty)
        }
    }

    @Test func stoppedDeLaStandaloneSegunElMomento() {
        #expect(GlassesStandaloneStop.decision(starting: false, requested: false) == .ignore)
        #expect(GlassesStandaloneStop.decision(starting: true, requested: false) == .setupFailed)
        #expect(GlassesStandaloneStop.decision(starting: true, requested: true) == .graceThenFail)
        #expect(GlassesStandaloneStop.decision(starting: false, requested: true) == .graceThenFail)
        #expect(GlassesStandaloneStop.stoppedGrace == 3)
        #expect(GlassesStandaloneStop.graceLog == "standalone stopped tras capturePhoto: esperando datos ≤3 s")
    }

    @Test func datosDentroDeLaGraciaSonFotoNormal() async throws {
        let once = GlassesOnce<Result<Data, Error>>()
        let got = Locked<Result<Data, Error>?>(nil)
        once.set { r in got.mutate { $0 = r } }
        let grace = GlassesStandaloneStop.armGrace(once, grace: 0.3)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(once.fire(.success(Data([0xFF]))))
        await grace.value
        #expect(try got.value?.get() == Data([0xFF]))
    }

    @Test func sinDatosLaGraciaVenceYFalla() async {
        let once = GlassesOnce<Result<Data, Error>>()
        let got = Locked<Result<Data, Error>?>(nil)
        once.set { r in got.mutate { $0 = r } }
        await GlassesStandaloneStop.armGrace(once, grace: 0.05).value
        #expect(throws: GlassesPhotoError.failed("cámara detenida tras capturePhoto sin entregar datos")) {
            try got.value?.get()
        }
    }

    @Test func graciaCanceladaEnElTeardownNoResuelve() async {
        let once = GlassesOnce<Result<Data, Error>>()
        let grace = GlassesStandaloneStop.armGrace(once, grace: 0.2)
        grace.cancel()
        await grace.value
        #expect(!once.isResolved)
    }

    @Test func pantallaDelPermisoEsValidaYSeCancela() throws {
        let view = HUDRenderer.render(.cameraPermission)
        try HUDValidator.validate(view)
        #expect(view.texts.contains { $0.content == "Aprueba la cámara en Meta AI y vuelve…" })
        #expect(view.actions.contains(.cancel))
        let state = HUDConversationState(screen: .capturing)
        let waiting = HUDStateMachine.reduce(state, .photoPhase(.awaitingPermission))
        #expect(waiting.state.screen == .cameraPermission)
        #expect(waiting.effects.isEmpty)
        let back = HUDStateMachine.reduce(waiting.state, .photoPhase(.capturing))
        #expect(back.state.screen == .capturing)
        for action in [HUDActionID.cancel, .back] {
            let cancelled = HUDStateMachine.reduce(waiting.state, .action(action))
            #expect(cancelled.state.screen == .home(status: nil))
            #expect(cancelled.effects == [.cancelCapture])
        }
        let failed = HUDStateMachine.reduce(waiting.state, .photoFailed("x"))
        #expect(failed.state.screen == .trouble(heading: HUDPhoto.failureHeading, message: "x"))
        let image = ContentBlock.text("img")
        let captured = HUDStateMachine.reduce(waiting.state, .photoCaptured(image))
        #expect(captured.effects == [.submitPhoto(image)])
        #expect(HUDStateMachine.reduce(waiting.state, .exited).effects == [.cancelCapture])
        #expect(HUDStateMachine.reduce(waiting.state, .cameraRequested(reason: "r")).effects == [.cancelCapture])
        // Fases tardías fuera de la foto no mueven la pantalla.
        let home = HUDConversationState(screen: .home(status: nil))
        #expect(HUDStateMachine.reduce(home, .photoPhase(.capturing)).state == home)
        #expect(HUDStateMachine.reduce(home, .photoPhase(.awaitingPermission)).state == home)
    }

    @Test func pantallaDeFalloEsValidaYVuelveConAtras() throws {
        let screen = HUDScreen.trouble(heading: HUDPhoto.failureHeading, message: "La foto no llegó a tiempo. Reintenta.")
        let view = HUDRenderer.render(screen)
        try HUDValidator.validate(view)
        #expect(view.texts.contains { $0.content == HUDPhoto.failureHeading })
        #expect(view.actions.contains(.back))
        let back = HUDStateMachine.reduce(HUDConversationState(screen: screen), .action(.back))
        #expect(back.state.screen == .home(status: nil))
    }
}

@Suite("Campo — la foto en el cuerpo: una en vuelo, tope y cancelación")
struct GlassesBodyPhotoTests {

    static func activeBody(_ runtime: MockRuntime = MockRuntime(), diagnostics: GlassesDiagnostics = GlassesDiagnostics())
        async throws -> GlassesBody {
        let body = GlassesBody(runtime: runtime, diagnostics: diagnostics)
        await body.start()
        runtime.setDevices([MockRuntime.display])
        _ = await eventually { await body.currentStatus().body == .dormant }
        try await body.ensureActive()
        _ = await body.waitUntilActive()
        return body
    }

    @Test func soloUnaCapturaEnVueloYLaSegundaEsBusy() async throws {
        let runtime = MockRuntime()
        let diag = GlassesDiagnostics()
        let body = try await Self.activeBody(runtime, diagnostics: diag)
        runtime.lastSession?.photoScript.mutate { $0 = stubbornCapture(0.4) }
        let first = Task { try await body.capturePhoto() }
        #expect(await eventually { await body.photoInFlight })
        await #expect(throws: GlassesPhotoError.busy) { _ = try await body.capturePhoto() }
        #expect(try await first.value == Data([0xFF]))
        #expect(await eventually { await !body.photoInFlight })
        #expect(runtime.lastSession?.photoCalls.value == 1)
        #expect(diag.entries.contains { $0.message == "rechazada: ya hay una captura en vuelo" })
        #expect(diag.entries.contains { $0.message.hasPrefix("foto recibida") })
    }

    @Test func elTopeDevuelveTimeoutYElHardwareSigueOcupadoHastaSoltarse() async throws {
        let runtime = MockRuntime()
        let diag = GlassesDiagnostics()
        let body = try await Self.activeBody(runtime, diagnostics: diag)
        await body.setPhotoDeadline(0.1)
        runtime.lastSession?.photoScript.mutate { $0 = stubbornCapture(0.6) }
        let started = Date()
        await #expect(throws: GlassesPhotoError.timeout) { _ = try await body.capturePhoto() }
        #expect(Date().timeIntervalSince(started) < 0.5)
        #expect(await body.photoInFlight)   // la captura vieja aún no suelta la cámara
        await #expect(throws: GlassesPhotoError.busy) { _ = try await body.capturePhoto() }
        #expect(await eventually { await !body.photoInFlight })
        #expect(diag.entries.contains { $0.message.hasPrefix("hardware libre") })
        runtime.lastSession?.photoScript.mutate { $0 = nil }
        await body.setPhotoDeadline(5)
        #expect(try await body.capturePhoto() == Data([0xFF, 0xD8, 0xFF]))
    }

    @Test func cancelarLaCapturaDevuelveCancellation() async throws {
        let runtime = MockRuntime()
        let diag = GlassesDiagnostics()
        let body = try await Self.activeBody(runtime, diagnostics: diag)
        runtime.lastSession?.photoScript.mutate { $0 = { try await Task.sleep(nanoseconds: 5_000_000_000); return Data() } }
        let task = Task { try await body.capturePhoto() }
        #expect(await eventually { await body.photoInFlight })
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await eventually { await !body.photoInFlight })
        #expect(diag.entries.contains { $0.message.hasPrefix("cancelada por el dueño") })
    }

    @Test func errorDelHardwareSePropagaYQuedaAnotado() async throws {
        let runtime = MockRuntime()
        let diag = GlassesDiagnostics()
        let body = try await Self.activeBody(runtime, diagnostics: diag)
        runtime.lastSession?.photo.mutate { $0 = .failure(GlassesPhotoError.setupFailed("timeout")) }
        await #expect(throws: GlassesPhotoError.setupFailed("timeout")) { _ = try await body.capturePhoto() }
        #expect(diag.entries.contains { $0.category == .photo && $0.message.hasPrefix("falló") })
    }

    @Test func elPermisoLentoNoConsumeElTopeDeLaFoto() async throws {
        let runtime = MockRuntime()
        let diag = GlassesDiagnostics()
        let body = try await Self.activeBody(runtime, diagnostics: diag)
        await body.setPhotoDeadline(0.2)
        let session = try #require(runtime.lastSession)
        session.permissionScript.mutate { $0 = { onPrompt in
            onPrompt()
            try await Task.sleep(nanoseconds: 600_000_000)   // el dueño tarda en Meta AI > tope de la foto
        } }
        let phases = Locked<[GlassesPhotoPhase]>([])
        let data = try await body.capturePhoto(onPhase: { p in phases.mutate { $0.append(p) } })
        #expect(data == Data([0xFF, 0xD8, 0xFF]))
        #expect(phases.value == [.awaitingPermission, .capturing])
        #expect(session.permissionCalls.value == 1)
        #expect(session.photoCalls.value == 1)
        #expect(await eventually { await !body.photoInFlight })
    }

    @Test func sinPermisoNoSeAbreLaCamaraNiSeEsperaElTope() async throws {
        let runtime = MockRuntime()
        let diag = GlassesDiagnostics()
        let body = try await Self.activeBody(runtime, diagnostics: diag)
        let session = try #require(runtime.lastSession)
        session.permissionScript.mutate { $0 = { _ in throw GlassesPhotoError.permissionDenied("denegado") } }
        let phases = Locked<[GlassesPhotoPhase]>([])
        await #expect(throws: GlassesPhotoError.permissionDenied("denegado")) {
            _ = try await body.capturePhoto(onPhase: { p in phases.mutate { $0.append(p) } })
        }
        #expect(await !body.photoInFlight)
        #expect(session.photoCalls.value == 0)
        #expect(phases.value.isEmpty)
        #expect(diag.entries.contains { $0.message.hasPrefix("sin permiso de cámara") })
        session.permissionScript.mutate { $0 = nil }
        #expect(try await body.capturePhoto() == Data([0xFF, 0xD8, 0xFF]))
    }

    @Test func cancelarEsperandoElPermisoLiberaLaFoto() async throws {
        let runtime = MockRuntime()
        let diag = GlassesDiagnostics()
        let body = try await Self.activeBody(runtime, diagnostics: diag)
        let session = try #require(runtime.lastSession)
        session.permissionScript.mutate { $0 = { onPrompt in
            onPrompt()
            try await Task.sleep(nanoseconds: 5_000_000_000)
        } }
        let task = Task { try await body.capturePhoto() }
        #expect(await eventually { await body.photoInFlight })
        #expect(await eventually { session.permissionCalls.value == 1 })
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await !body.photoInFlight)
        #expect(session.photoCalls.value == 0)
        #expect(diag.entries.contains { $0.message.hasPrefix("cancelada por el dueño esperando el permiso") })
    }

    @Test func sinSesionNoCaptura() async {
        let diag = GlassesDiagnostics()
        let body = GlassesBody(runtime: MockRuntime(), diagnostics: diag)
        await #expect(throws: GlassesBodyError.self) { _ = try await body.capturePhoto() }
        #expect(diag.entries.last?.message == "rechazada: sin sesión activa")
    }
}

@Suite("Campo — 'Tomando la foto…' siempre sale")
@MainActor
struct GlassesPhotoScreenTests {

    @Test func camaraColgadaTerminaEnErrorVisibleYVuelveAlHome() async throws {
        let runtime = MockRuntime()
        let body = try await GlassesBodyPhotoTests.activeBody(runtime)
        await body.setPhotoDeadline(0.15)
        runtime.lastSession?.photoScript.mutate { $0 = stubbornCapture(2) }
        let voice = MockVoice()
        let surface = GlassesHUDSurface(body: body, runner: MockRunner(), sessionId: "s", voice: voice, speech: voice,
                                        errorDwell: 0.2)
        await surface.start()
        await surface.handle(.action(.photo))
        #expect(surface.state.screen == .capturing)
        let timedOut = HUDScreen.trouble(heading: HUDPhoto.failureHeading, message: "La foto no llegó a tiempo. Reintenta.")
        #expect(await eventually(3) { await surface.state.screen == timedOut })
        #expect(await eventually(3) { await surface.state.screen == .home(status: nil) })
        // Mientras la vieja sigue ocupando el hardware, reintentar avisa claro.
        await surface.handle(.action(.photo))
        let busy = HUDScreen.trouble(heading: HUDPhoto.failureHeading, message: "Ya hay una foto en curso. Espera unos segundos.")
        #expect(await eventually(3) { await surface.state.screen == busy })
        surface.stop()
    }

    @Test func esperandoMetaAIMuestraSuPantallaYLuegoCaptura() async throws {
        let runtime = MockRuntime()
        let body = try await GlassesBodyPhotoTests.activeBody(runtime)
        await body.setPhotoDeadline(0.15)
        let session = try #require(runtime.lastSession)
        let release = Locked(false)
        session.permissionScript.mutate { $0 = { onPrompt in
            onPrompt()
            while !release.value { try await Task.sleep(nanoseconds: 10_000_000) }
        } }
        session.photoScript.mutate { $0 = { throw GlassesPhotoError.failed("x") } }
        let voice = MockVoice()
        let surface = GlassesHUDSurface(body: body, runner: MockRunner(), sessionId: "s", voice: voice, speech: voice,
                                        errorDwell: 5)
        await surface.start()
        await surface.handle(.action(.photo))
        #expect(await eventually(3) { await surface.state.screen == .cameraPermission })
        // Más que el tope de la foto en Meta AI: no hay "no llegó a tiempo".
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(surface.state.screen == .cameraPermission)
        release.mutate { $0 = true }
        let failed = HUDScreen.trouble(heading: HUDPhoto.failureHeading, message: "La foto falló. Reintenta.")
        #expect(await eventually(3) { await surface.state.screen == failed })
        surface.stop()
    }

    @Test func cancelarEnLaPantallaDelPermisoVuelveAlHomeYLibera() async throws {
        let runtime = MockRuntime()
        let body = try await GlassesBodyPhotoTests.activeBody(runtime)
        let session = try #require(runtime.lastSession)
        session.permissionScript.mutate { $0 = { onPrompt in
            onPrompt()
            try await Task.sleep(nanoseconds: 5_000_000_000)
        } }
        let voice = MockVoice()
        let surface = GlassesHUDSurface(body: body, runner: MockRunner(), sessionId: "s", voice: voice, speech: voice,
                                        errorDwell: 0.05)
        await surface.start()
        await surface.handle(.action(.photo))
        #expect(await eventually(3) { await surface.state.screen == .cameraPermission })
        await surface.handle(.action(.cancel))
        #expect(surface.state.screen == .home(status: nil))
        #expect(await eventually { await !body.photoInFlight })
        #expect(session.photoCalls.value == 0)
        surface.stop()
    }

    @Test func cancelarDuranteLaCapturaNoMuestraErrorDespues() async throws {
        let runtime = MockRuntime()
        let body = try await GlassesBodyPhotoTests.activeBody(runtime)
        runtime.lastSession?.photoScript.mutate { $0 = { try await Task.sleep(nanoseconds: 300_000_000); throw MockError("tarde") } }
        let voice = MockVoice()
        let surface = GlassesHUDSurface(body: body, runner: MockRunner(), sessionId: "s", voice: voice, speech: voice,
                                        errorDwell: 0.05)
        await surface.start()
        await surface.handle(.action(.photo))
        #expect(await eventually { await body.photoInFlight })
        await surface.handle(.action(.cancel))
        #expect(surface.state.screen == .home(status: nil))
        #expect(await eventually { await !body.photoInFlight })
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(surface.state.screen == .home(status: nil))
        surface.stop()
    }
}
