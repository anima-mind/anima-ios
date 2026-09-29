import Foundation
import Testing
@testable import AnimaKit

@Suite("GlassesActivation — cuándo se enciende el cuerpo (G0: card de bienvenida)")
struct GlassesActivationTests {

    @Test func alVolverseElegibleActivaYMuestraLaBienvenida() async throws {
        let runtime = MockRuntime()
        let body = GlassesBody(runtime: runtime)
        await body.start()
        let activation = GlassesActivation(body: body)
        await activation.start()
        await activation.start()   // idempotente
        runtime.setDevices([MockRuntime.display])
        #expect(await eventually { await body.currentStatus().body == .active })
        let display = try #require(runtime.lastSession?.display)
        #expect(await eventually { !display.sent.value.isEmpty })
        let welcome = try #require(display.sent.value.first)
        #expect(welcome.isRoot)
        #expect(welcome.texts.contains { $0.content == "anima 👋" })
        #expect(runtime.sessions.value.count == 1)
        await activation.stop()
    }

    @Test func trasSalirNoSeReabreSolaHastaInteraccion() async throws {
        let runtime = MockRuntime()
        let body = GlassesBody(runtime: runtime)
        let activation = GlassesActivation(body: body)
        await body.setHandlers(onAction: nil, onExit: { Task { await activation.userExited() } })
        await body.start()
        await activation.start()
        runtime.setDevices([MockRuntime.display])
        #expect(await eventually { await body.currentStatus().body == .active })

        runtime.lastSession?.endFromDevice()   // back físico
        #expect(await eventually { await body.currentStatus().body == .dormant })
        #expect(await body.currentStatus().endedByDevice)
        #expect(await eventually { await activation.isSuppressed })
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(runtime.sessions.value.count == 1, "no se re-abrió sola")

        await activation.userRequested()   // "Mostrar en las gafas"
        #expect(await eventually { await body.currentStatus().body == .active })
        #expect(runtime.sessions.value.count == 2)
        #expect(runtime.liveSessions == 1)

        runtime.lastSession?.endFromDevice()
        #expect(await eventually { await body.currentStatus().body == .dormant })
        await activation.setForeground(false)
        await activation.setForeground(true)   // volver a primer plano = interacción
        #expect(await eventually { await body.currentStatus().body == .active })
        #expect(runtime.liveSessions == 1)
    }

    @Test func enSegundoPlanoNoActiva() async throws {
        let runtime = MockRuntime()
        let body = GlassesBody(runtime: runtime)
        await body.start()
        let activation = GlassesActivation(body: body, initialView: { _ in HUDRenderer.render(.handoff) })
        await activation.setForeground(false)
        await activation.start()
        runtime.setDevices([MockRuntime.display])
        #expect(await eventually { await body.currentStatus().body == .dormant })
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(runtime.sessions.value.isEmpty)
        #expect(await activation.activate())
        #expect(await body.lastRendered()?.name == "handoff")
        // Sin device elegible, activar falla sin romper.
        let lonely = GlassesActivation(body: GlassesBody(runtime: MockRuntime(registration: .available)))
        #expect(await lonely.activate() == false)
    }
}
