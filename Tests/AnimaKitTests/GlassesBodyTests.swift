import Foundation
import Testing
@testable import AnimaKit

@Suite("GlassesBody — sesión única, teardown, re-suscripción y dolencias")
struct GlassesBodyTests {

    static func key(_ errorClass: String) -> PatternKey {
        PatternKey(toolName: "glasses", argShape: "<body>", errorClass: errorClass, targetResource: nil)
    }

    @Test func sinConfiguracionElCuerpoEsSoloTelefono() async {
        let body = GlassesBody(runtime: MockRuntime(configureError: MockError("sin MetaAppID")))
        await body.start()
        await body.start()   // idempotente
        let status = await body.currentStatus()
        #expect(status.body == .absent)
        #expect(!status.configured)
        #expect(status.lastError?.contains("sin MetaAppID") == true)
        #expect(status.bodyLabel == "solo teléfono")
        #expect(status.statusLine.contains("solo teléfono"))
        await #expect(throws: GlassesBodyError.unavailable("gafas no conectadas")) { try await body.ensureActive() }
    }

    @Test func runtimeAusenteNoRompeNada() async throws {
        let runtime = AbsentGlassesRuntime()
        #expect(throws: AbsentGlassesRuntime.Unavailable()) { try runtime.configure() }
        #expect(await runtime.registrationState() == .unavailable)
        #expect(try await runtime.handleURL(URL(string: "anima://x")!) == false)
        await #expect(throws: AbsentGlassesRuntime.Unavailable()) { try await runtime.startRegistration() }
        await #expect(throws: AbsentGlassesRuntime.Unavailable()) { try await runtime.startUnregistration() }
        await #expect(throws: AbsentGlassesRuntime.Unavailable()) { try await runtime.openDATGlassesAppUpdate() }
        #expect(throws: AbsentGlassesRuntime.Unavailable()) { _ = try runtime.makeSession() }
        for await _ in runtime.registrationUpdates() { Issue.record("no debería emitir") }
        for await _ in runtime.deviceUpdates() { Issue.record("no debería emitir") }
        #expect(!AbsentGlassesRuntime.Unavailable().description.isEmpty)
    }

    @Test func registroYElegibilidadPorCompatibilidad() async throws {
        let runtime = MockRuntime(registration: .available)
        let body = GlassesBody(runtime: runtime)
        await body.start()
        #expect(await body.currentStatus().body == .absent)
        try await body.register()
        #expect(runtime.registerCalls.value == 1)
        #expect(try await body.handleURL(URL(string: "anima://dat?ok=1")!))
        #expect(runtime.urls.value.count == 1)

        runtime.setRegistration(.registered)
        #expect(await eventually { await body.currentStatus().registration == .registered })
        try await body.register()   // ya registrado: no re-registra
        #expect(runtime.registerCalls.value == 1)

        // Conectado pero la compatibilidad aún no llega (.undefined): no elegible.
        var device = MockRuntime.display
        device.compatibility = .undefined
        runtime.setDevices([device])
        #expect(await eventually { await body.currentStatus().body == .incompatible })
        #expect(await body.currentStatus().bodyLabel == "gafas incompatibles")
        // El listener de compatibilidad llega tarde → elegible.
        device.compatibility = .compatible
        runtime.setDevices([device])
        #expect(await eventually { await body.currentStatus().body == .dormant })
        #expect(await body.currentStatus().deviceName == "Meta Ray-Ban Display")
    }

    @Test func versionIncompatibleVaAlRealRegister() async throws {
        let queue = try AnimaDatabase.temporary()
        let register = RealRegister(queue: queue)
        let runtime = MockRuntime()
        let body = GlassesBody(runtime: runtime, realRegister: register)
        await body.start()
        var device = MockRuntime.display
        device.compatibility = .sdkUpdateRequired
        runtime.setDevices([device])
        #expect(await eventually { await body.currentStatus().body == .incompatible })
        #expect(await eventually { await register.insistence(Self.key("glasses_version_mismatch")) == 1 })
        #expect(await body.currentStatus().statusLine.contains("incompatibles"))
    }

    @Test func activaRenderizaYReenviaAlDespertar() async throws {
        let runtime = MockRuntime()
        let body = await readyBody(runtime)
        let welcome = HUDRenderer.render(.home(status: nil))
        await body.render(welcome)   // aún sin display: queda como vista actual
        try await body.ensureActive()
        try await body.ensureActive()   // idempotente: jamás una segunda sesión
        #expect(await body.waitUntilActive())
        #expect(await body.sessionsCreated == 1)
        #expect(runtime.sessions.value.count == 1)
        let status = await body.currentStatus()
        #expect(status.body == .active)
        #expect(status.statusLine.contains("gafas conectadas"))
        #expect(status.bodyLabel == "gafas conectadas")

        let display = try #require(runtime.lastSession?.display)
        #expect(await eventually { display.sent.value.count == 1 })
        #expect(display.sent.value.first == welcome)
        #expect(await body.lastRendered() == welcome)

        // Sueño del display → wake: re-envía la vista completa.
        display.sleep()
        #expect(await eventually { await body.currentStatus().body == .connecting })
        display.wake()
        #expect(await eventually { display.sent.value.count == 2 })

        // Render nuevo con display activo: se envía de inmediato.
        await body.render(HUDRenderer.render(.handoff))
        #expect(display.sent.value.count == 3)
    }

    @Test func accionesDelHUDLleganAlHandler() async throws {
        let runtime = MockRuntime()
        let body = await readyBody(runtime)
        let actions = Locked<[HUDActionID]>([])
        await body.setHandlers(onAction: { a in actions.mutate { $0.append(a) } }, onExit: nil)
        try await body.ensureActive()
        #expect(await body.waitUntilActive())
        await body.render(HUDRenderer.render(.home(status: nil)))
        runtime.lastSession?.display.tap(.talk)
        #expect(actions.value == [.talk])
    }

    @Test func veinteCiclosSinSesionesZombie() async throws {
        let runtime = MockRuntime()
        let body = await readyBody(runtime)
        let exits = Locked(0)
        await body.setHandlers(onAction: nil, onExit: { exits.mutate { $0 += 1 } })
        for cycle in 1...20 {
            try await body.ensureActive()
            #expect(await body.waitUntilActive(), "ciclo \(cycle)")
            #expect(runtime.liveSessions == 1, "ciclo \(cycle): sesiones vivas")
            // Alterna las 3 salidas del mundo real: back físico, quitarse las gafas, teardown propio.
            let session = try #require(runtime.lastSession)
            switch cycle % 3 {
            case 0: session.endFromDevice()
            case 1: session.fault(.hingesClosed)
            default: await body.teardown()
            }
            #expect(await eventually { await !body.hasSession }, "ciclo \(cycle)")
            #expect(await eventually { await body.currentStatus().body == .dormant })
            #expect(runtime.liveSessions == 0, "ciclo \(cycle): zombie")
        }
        #expect(await body.sessionsCreated == 20)
        #expect(runtime.sessions.value.allSatisfy { $0.stopped.value >= 1 })
        #expect(exits.value == 13)   // back (6) + doff (7) avisan; el teardown propio (7) no
    }

    @Test func eventosDeUnaSesionViejaSeIgnoran() async throws {
        let runtime = MockRuntime()
        runtime.nextSession.mutate { $0 = { MockSession(autoStart: false) } }
        let body = await readyBody(runtime)
        try await body.ensureActive()
        let old = try #require(runtime.lastSession)
        await body.teardown()
        // Re-suscripción: nueva generación con streams propios.
        runtime.nextSession.mutate { $0 = nil }
        try await body.ensureActive()
        #expect(await body.waitUntilActive())
        let fresh = try #require(runtime.lastSession)
        #expect(fresh !== old)
        await body.onSessionState(.started, generation: 1)   // generación vieja
        await body.onSessionState(.stopped, generation: 1)
        await body.onFault(.thermalCritical, generation: 1)
        await body.onDisplayState(.stopped, generation: 1)
        #expect(await body.hasSession)
        #expect(await body.currentStatus().body == .active)
    }

    @Test func dolenciasFisicasSonFallosTipados() async throws {
        let cases: [(GlassesFault, GlassesAilment, String)] = [
            (.thermalCritical, .thermal, "glasses_thermal"),
            (.thermalEmergency, .thermal, "glasses_thermal"),
            (.batteryCritical, .battery, "glasses_battery"),
            (.peakPowerShutdown, .battery, "glasses_battery"),
            (.datAppUpdateRequired, .updateRequired, "glasses_version_mismatch"),
        ]
        for (fault, ailment, errorClass) in cases {
            let register = RealRegister(queue: try AnimaDatabase.temporary())
            let runtime = MockRuntime()
            let body = await readyBody(runtime, realRegister: register)
            let exits = Locked(0)
            await body.setHandlers(onAction: nil, onExit: { exits.mutate { $0 += 1 } })
            try await body.ensureActive()
            #expect(await body.waitUntilActive())
            runtime.lastSession?.fault(fault)
            #expect(await eventually { await body.currentStatus().body == .ailing(ailment) }, "\(fault)")
            #expect(await register.insistence(Self.key(errorClass)) == 1)
            #expect(runtime.liveSessions == 0)
            #expect(exits.value == 1)
            let status = await body.currentStatus()
            #expect(status.statusLine.contains("problema"))
            #expect(status.bodyLabel.hasPrefix("gafas · "))
            // Se puede reintentar: la dolencia se limpia al re-activar.
            try await body.ensureActive()
            #expect(await body.waitUntilActive())
            #expect(await body.currentStatus().body == .active)
            await body.teardown()
        }
        #expect(GlassesAilment.versionMismatch.errorClass == "glasses_version_mismatch")
        #expect(GlassesStatus.ailmentLabel(.versionMismatch) == "versión no compatible")
    }

    @Test func otrosFallosDeSesion() async throws {
        let register = RealRegister(queue: try AnimaDatabase.temporary())
        let runtime = MockRuntime()
        let body = await readyBody(runtime, realRegister: register)
        try await body.ensureActive()
        #expect(await body.waitUntilActive())
        runtime.lastSession?.fault(.other("ruido"))
        #expect(await eventually { await body.currentStatus().lastError == "ruido" })
        runtime.lastSession?.fault(.noEligibleDevice)
        #expect(await eventually { await !body.hasSession })
        #expect(await register.insistence(Self.key("glasses_unavailable")) == 1)
    }

    @Test func fallosAlAbrirLaSesion() async throws {
        let register = RealRegister(queue: try AnimaDatabase.temporary())
        let runtime = MockRuntime()
        let body = await readyBody(runtime, realRegister: register)

        runtime.makeError.mutate { $0 = MockError("claimed") }
        await #expect(throws: GlassesBodyError.self) { try await body.ensureActive() }
        #expect(await body.currentStatus().lastError?.contains("claimed") == true)
        runtime.makeError.mutate { $0 = nil }

        runtime.nextSession.mutate { $0 = { MockSession(startError: MockError("no start")) } }
        await #expect(throws: GlassesBodyError.self) { try await body.ensureActive() }
        #expect(await !body.hasSession)
        #expect(runtime.liveSessions == 0)

        runtime.nextSession.mutate { $0 = { MockSession(displayError: MockError("no display")) } }
        try await body.ensureActive()
        #expect(await eventually { await body.currentStatus().lastError?.contains("no display") == true })
        #expect(await body.waitUntilActive(timeout: 0.05) == false)
        #expect(await register.insistence(Self.key("glasses_unavailable")) == 2)
        await body.teardown()
    }

    @Test func desconexionYDesregistroHacenTeardown() async throws {
        let runtime = MockRuntime()
        let body = await readyBody(runtime)
        try await body.ensureActive()
        #expect(await body.waitUntilActive())
        var gone = MockRuntime.display
        gone.link = .disconnected
        runtime.setDevices([gone])
        #expect(await eventually { await !body.hasSession })
        #expect(await body.currentStatus().body == .absent)
        #expect(await body.currentStatus().bodyLabel == "gafas lejos")

        runtime.setDevices([MockRuntime.display])
        #expect(await eventually { await body.currentStatus().body == .dormant })
        try await body.ensureActive()
        try await body.unregister()
        #expect(runtime.unregisterCalls.value == 1)
        #expect(runtime.liveSessions == 0)
        runtime.setRegistration(.available)
        #expect(await eventually { await body.currentStatus().body == .absent })
        try await body.openDATGlassesAppUpdate()
        #expect(runtime.updateCalls.value == 1)
    }

    @Test func camaraRequiereSesionActiva() async throws {
        let runtime = MockRuntime()
        let body = await readyBody(runtime)
        await #expect(throws: GlassesBodyError.unavailable("gafas no conectadas")) { try await body.capturePhoto() }
        try await body.ensureActive()
        #expect(await body.waitUntilActive())
        #expect(try await body.capturePhoto() == Data([0xFF, 0xD8, 0xFF]))
    }

    @Test func erroresDeEnvio() async throws {
        let runtime = MockRuntime()
        let body = await readyBody(runtime)
        try await body.ensureActive()
        #expect(await body.waitUntilActive())
        let display = try #require(runtime.lastSession?.display)
        display.sendError.mutate { $0 = MockError("Superseded by new display request") }
        await body.render(HUDRenderer.render(.handoff))
        #expect(await body.currentStatus().lastError == nil)
        display.sendError.mutate { $0 = MockError("bt caído") }
        await body.render(HUDRenderer.render(.handoff))
        #expect(await body.currentStatus().lastError == "HUD send: bt caído")
    }

    @Test func streamDeEstado() async throws {
        let runtime = MockRuntime()
        let body = await readyBody(runtime)
        let seen = Locked<[GlassesBodyState]>([])
        let stream = await body.statusUpdates()
        let task = Task { for await s in stream { seen.mutate { $0.append(s.body) } } }
        try await body.ensureActive()
        #expect(await eventually { seen.value.contains(.active) })
        #expect(seen.value.first == .dormant)
        task.cancel()
    }

    @Test func etiquetasDeEstado() {
        var s = GlassesStatus(body: .active, configured: true, registration: .registered, batteryPercent: 72)
        #expect(s.statusLine.hasPrefix("Cuerpo: gafas conectadas · batería 72%"))
        s.body = .connecting
        #expect(s.bodyLabel == "gafas conectando")
        #expect(s.statusLine.contains("reposo"))
        s.body = .dormant
        #expect(s.bodyLabel == "gafas en reposo")
        #expect(s.isRegistered)
        #expect(!s.isActive)
        #expect(GlassesBodyError.unavailable("x").description == "x")
    }
}

@Suite("Estado corporal → system volátil (camino top-level del builder)")
struct BodyStatusLineTests {

    @Test func statusLineVaAlSystemTopLevelNoAMessages() async throws {
        let store = SymbolicStore(queue: try AnimaDatabase.temporary())
        let sid = try store.startSession()
        let memory = WorkingMemory(store: store)
        let line = GlassesStatus(body: .active, configured: true, registration: .registered).statusLine
        await memory.updateBodyStatus(line)
        await memory.updateSurfaceHint("[superficie: gafas]")
        let messages = try await memory.assemble(.text("hola", sessionId: sid))
        #expect(messages.contains { $0.role == .system && $0.content == [.text(line + "\n[superficie: gafas]")] })

        let request = try ClaudeRequestBuilder.build(context: AssembledContext(messages: messages), tools: [],
                                                     opts: try TestConfig.callOpts(authMode: .apiKey))
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        guard case .array(let system)? = body["system"], case .array(let wire)? = body["messages"] else {
            Issue.record("sin system/messages"); return
        }
        #expect(system.last?["text"]?.stringValue?.contains(line) == true)
        #expect(!wire.contains { $0["role"]?.stringValue == "system" })

        await memory.updateBodyStatus(nil)
        await memory.updateSurfaceHint(nil)
        let clean = try await memory.assemble(.text("hola", sessionId: sid))
        #expect(!clean.contains { $0.role == .system && ($0.content.first.map { "\($0)" } ?? "").contains("Cuerpo:") })
    }

    @Test func elLoopRefrescaElEstadoCorporalCadaTurno() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let provider = CapturingProvider([.text("ok"), .text("ok")])
        let state = Locked("Cuerpo: solo teléfono")
        let loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [], serverTools: [],
                             bodyStatus: { state.value }, sleep: { _ in })
        let sid = try store.startSession()
        for await _ in await loop.run(sessionId: sid, userText: "hola") {}
        state.mutate { $0 = "Cuerpo: gafas conectadas" }
        for await _ in await loop.run(sessionId: sid, userText: "otra") {}
        let systems = provider.captures.value.map { capture in
            capture.messages.filter { $0.role == .system }.flatMap(\.content)
        }
        #expect(systems[0].contains(.text("Cuerpo: solo teléfono")))
        #expect(systems[1].contains(.text("Cuerpo: gafas conectadas")))
    }
}
