import Foundation
import Testing
@testable import AnimaKit

// Campo #6: el back físico TERMINA la sesión siempre (no llega a la app): toda
// navegación es nuestra vía "Atrás". Sin callejones + re-entrada tras salir.

@Suite("Campo — HUD sin callejones y re-entrada")
struct GlassesNavigationTests {
    typealias S = HUDConversationState

    static let card = HUDCard(heading: "h", body: "b")
    static let nonHome: [HUDScreen] = [
        .capturing, .listening(viaPhone: false), .listening(viaPhone: true), .heard(transcript: "t"),
        .thinking(question: "q"), .speaking(card), .answer(card), .declined("no"), .attention("x"),
        .cameraConfirm(reason: "r"),
        .agentCard(HUDFlexBox(background: .card, children: [.text(HUDText("Hola"))])), .handoff,
    ]

    @Test func todaPantallaNoHomeTieneAtrasVisibleQueLlevaAlHome() throws {
        for screen in Self.nonHome {
            let view = HUDRenderer.render(screen)
            try HUDValidator.validate(view)
            #expect(!view.isRoot, "\(view.name)")
            let back = try #require(view.buttons.first { $0.action == .back }, "\(view.name) sin Atrás")
            #expect(back.label == "Atrás")
            // Presupuesto: máx. 2 botones propios + nuestro Atrás.
            #expect(view.buttons.count <= HUDValidator.maxButtons, "\(view.name)")
            let out = HUDStateMachine.reduce(S(screen: screen, status: "ok"), .action(.back))
            #expect(out.state.screen == .home(status: "ok"), "\(view.name) no vuelve al Home")
        }
    }

    @Test func homeEsElHubConMenu() {
        let home = HUDRenderer.render(.home(status: "Batería 80%"))
        #expect(home.isRoot)
        #expect(home.buttons.map(\.action) == [.talk, .photo])
        #expect(home.texts.contains { $0.content == "Batería 80%" })
    }

    @Test func deepLinkDeReentrada() {
        #expect(AnimaDeepLink.glasses.url.absoluteString == "anima://glasses")
        #expect(AnimaDeepLink.parse(AnimaDeepLink.glasses.url) == .glasses)
        #expect(AnimaDeepLink.parse(URL(string: "anima://?metaWearablesAction=register")!) == nil)
    }

    @Test func backFisicoEnBackgroundAvisaConNotificacionYElDeepLinkReactiva() async throws {
        let runtime = MockRuntime()
        let body = GlassesBody(runtime: runtime)
        let posted = Locked(0)
        let activation = GlassesActivation(body: body, reentry: { posted.mutate { $0 += 1 } })
        await body.setHandlers(onAction: nil, onExit: { Task { await activation.userExited() } })
        await body.start()
        await activation.start()
        runtime.setDevices([MockRuntime.display])
        #expect(await eventually { await body.currentStatus().body == .active })

        // Con la app al frente: sin notificación (Ajustes tiene "Mostrar en las gafas").
        runtime.lastSession?.endFromDevice()
        #expect(await eventually { await activation.isSuppressed })
        #expect(posted.value == 0)

        await activation.userRequested()
        #expect(await eventually { await body.currentStatus().body == .active })
        // Teléfono en el bolsillo (background) + back físico → "Anima sigue aquí".
        await activation.setForeground(false)
        runtime.lastSession?.endFromDevice()
        #expect(await eventually { posted.value == 1 })
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(runtime.liveSessions == 0, "el SDK no permite reabrir sola desde background")
        // Tocar la notificación foregroundea la app y reactiva.
        await activation.setForeground(true)
        #expect(await eventually { await body.currentStatus().body == .active })
        #expect(runtime.liveSessions == 1)
    }
}
