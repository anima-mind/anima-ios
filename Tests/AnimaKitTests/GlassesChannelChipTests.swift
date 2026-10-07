import Foundation
import Testing
@testable import AnimaKit

// Campo batch 8 #2: "lo que hablo en las gafas no se ve en el historial con el
// tag de gafas, como las notas de voz transcritas". El surface SÍ se guardaba
// (v9-turn-surface, AgentLoop lo persiste), pero el chat lo ignoraba: un turno
// de voz en las gafas salía con el chip "voz" y el espejo en vivo sin nada.

@MainActor
@Suite("Batch 8 #2 — chip \"gafas\" en los turnos del dueño hechos desde las gafas")
struct GlassesChannelChipTests {

    @Test func vozEnLasGafasSePersisteYSePintaConGafas() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let loop = AgentLoop(provider: ScriptedProvider([LocalLoopHarness.text("Mañana: standup a las 9."),
                                                         LocalLoopHarness.text("Veo una taza.")]),
                             store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-x", clientTools: [], serverTools: [], sleep: { _ in })
        let sid = try store.startSession()
        let router = SurfaceRouter()
        let phone = ChatViewModel(loop: loop, sessionId: sid)
        router.register(phone)
        let rig = await GlassesRig.make()
        let surface = GlassesHUDSurface(body: rig.body, runner: loop, sessionId: sid, voice: rig.voice,
                                        speech: rig.voice, router: router)
        await surface.start()

        // Turno de voz por el HUD real → AgentLoop real.
        await surface.handle(.action(.talk))
        rig.voice.cancel()
        await surface.handle(.transcript("¿qué tengo mañana?"))
        await surface.handle(.action(.send))
        #expect(await eventually { await MainActor.run {
            phone.messages.contains { $0.role == .assistant && $0.text == "Mañana: standup a las 9." } } })

        // Espejo en vivo: el turno del dueño lleva el canal.
        let live = try #require(phone.messages.first { $0.role == .user })
        #expect(live.surface == .glassesHUD)
        #expect(live.channelChip?.label == "gafas" && live.channelChip?.glyph == "eyeglasses")

        // Foto desde las gafas: mismo canal.
        for await _ in await loop.run(sessionId: sid, content: [.text(HUDPhoto.prompt),
                                                                .image(mediaType: "image/jpeg", base64: "QUJD")],
                                      surface: .glassesHUD) {}

        // Persistido y leído por el historial (loadHistory/historyPage).
        let surfaces = try store.surfaces(sessionId: sid)
        #expect(surfaces.first == .glassesHUD)
        let history = ChatViewModel.history(turns: try store.historyPage().turns, boundaries: [:])
        let owner = history.filter { $0.role == .user }
        #expect(owner.map(\.text) == ["¿qué tengo mañana?", HUDPhoto.question])
        #expect(owner.allSatisfy { $0.surface == .glassesHUD && $0.channelChip?.label == "gafas" })
        surface.stop()
    }

    @Test func vozDelTelefonoSigueSiendoVozYLoEscritoNoLlevaChip() {
        var voice = ChatViewModel.DisplayMessage(role: .user, text: "hola", isVoice: true)
        #expect(voice.channelChip?.label == "voz")
        voice.surface = .phoneChat
        #expect(voice.channelChip?.label == "voz")
        #expect(ChatViewModel.DisplayMessage(role: .user, text: "hola").channelChip == nil)
        var reply = ChatViewModel.DisplayMessage(role: .assistant, text: "ok")
        reply.surface = .glassesHUD
        #expect(reply.channelChip == nil)   // solo los turnos del dueño
        var typed = VisibleTurn(role: .user, text: "escrito")
        typed.surface = .phoneChat
        #expect(ChatViewModel.history(turns: [typed], boundaries: [:]).first?.channelChip == nil)
    }
}

@MainActor
@Suite("Review #34 — en las gafas lo retraído no se sigue diciendo")
struct GlassesRetractionTests {
    @Test func laRespuestaCorregidaReemplazaAlTramoRetraido() async throws {
        let rig = await GlassesRig.make()
        rig.runner.replies.mutate { $0 = [[
            .textDelta("Primero reviso. "), .assistantMessage([.text("Primero reviso. ")]),
            .textDelta("Quedó agendado. "), .retracted,
            .textDelta("No hice cambios."), .turnFinished(stopReason: .endTurn),
        ]] }
        await rig.surface.handle(.action(.talk))
        rig.voice.cancel()
        await rig.surface.handle(.transcript("agéndalo"))
        await rig.surface.handle(.action(.send))
        #expect(await eventually { await MainActor.run {
            rig.phone.rendered.contains(.assistantTurn(text: "Primero reviso. No hice cambios.", origin: .glassesHUD)) } })
        #expect(await eventually { rig.voice.spoken.value.contains { $0.contains("No hice cambios") } })
        #expect(!rig.voice.spoken.value.contains { $0.contains("Quedó agendado") })
    }
}
