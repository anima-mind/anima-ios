import Foundation
import Testing
@testable import AnimaKit

// Campo #10: cerrar y reabrir dejaba el chat VACÍO (Recovery descableado).
// Política: reanudar la última sesión salvo >8 h sin actividad; el chat carga
// los turnos visibles persistidos.

@Suite("Campo — reanudar la sesión al abrir y cargar el historial")
struct SessionResumeTests {

    @Test func menosDe8HorasReanudaMasDe8HorasNueva() throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let recovery = Recovery(queue: queue, store: store)
        #expect(try recovery.decideLaunch() == .fresh(previous: nil))   // primera vez

        let sid = try store.startSession()
        try store.append(sessionId: sid, message: .user("hola"))
        try store.markCleanShutdown(sid)   // la app pasó a background limpia
        let now = Date()
        // 7 h 59 min después (reloj inyectado): la misma conversación.
        #expect(try recovery.decideLaunch(now: now.addingTimeInterval(8 * 3600 - 60)) == .resume(sid))
        #expect(try store.session(sid)?.cleanShutdown == false)   // vuelve a estar viva
        #expect(try store.session(sid)?.restartCount == 0)        // cierre limpio: no es reinicio
        // 8 h 1 min: el sueño separa el episodio → sesión nueva con la anterior visible.
        #expect(try recovery.decideLaunch(now: now.addingTimeInterval(8 * 3600 + 60)) == .fresh(previous: sid))
    }

    @Test func crashSinMarcaReanudaConTope() throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let recovery = Recovery(queue: queue, store: store, maxRestarts: 2)
        let sid = try store.startSession()
        try store.append(sessionId: sid, message: .user("a mitad de turno"))
        // Sin markCleanShutdown: jetsam / crash.
        #expect(try recovery.decideLaunch() == .resume(sid))
        #expect(try store.session(sid)?.restartCount == 1)
        #expect(try recovery.decideLaunch() == .resume(sid))
        // Tope de reinicios sucios: sesión fresca (no se re-entra en bucle).
        #expect(try recovery.decideLaunch() == .fresh(previous: sid))
        // Sesión sin eventos: cuenta desde que empezó.
        let empty = try store.startSession()
        #expect(try recovery.decideLaunch() == .resume(empty))
    }

    @Test func turnosVisiblesSinToolsNiRazonamiento() throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let sid = try store.startSession()
        try store.append(sessionId: sid, message: .user("¿qué tengo mañana?"))
        try store.append(sessionId: sid, message: Message(role: .assistant, content: [
            .thinking("pensando"), .text("Déjame ver."), .toolUse(id: "t1", name: "calendar", input: .null)]))
        try store.append(sessionId: sid, message: Message(role: .user, content: [
            .toolResult(toolUseId: "t1", content: "[]", isError: false)]))
        try store.append(sessionId: sid, message: Message(role: .assistant, content: [.text("**Libre** todo el día.")]))
        try store.append(sessionId: sid, message: Message(role: .user, content: [AudioTool.transcriptBlock("gracias")]),
                         surface: .glassesHUD)
        try store.append(sessionId: sid, message: Message(role: .user, content: [
            .text(HUDPhoto.prompt), .image(mediaType: "image/jpeg", base64: "QUJD")]), surface: .glassesHUD)
        try store.append(sessionId: sid, message: Message(role: .assistant, content: [
            .toolUse(id: "t2", name: "glasses_show", input: .null)]))
        try store.append(sessionId: sid, message: Message(role: .system, content: [.text("pista")]))

        let turns = try store.visibleTurns(sessionId: sid)
        #expect(turns.map(\.text) == ["¿qué tengo mañana?", "Déjame ver.", "**Libre** todo el día.", "gracias",
                                      HUDPhoto.question])
        #expect(turns.map(\.role) == [.user, .assistant, .assistant, .user, .user])
        #expect(turns[3].isVoice); #expect(turns[3].surface == .glassesHUD)
        #expect(turns[4].imageBase64 == "QUJD")
        #expect(!turns[0].isVoice); #expect(turns[0].surface == nil)
    }
}

@Suite("Campo — el chat abre con el historial")
@MainActor
struct ChatHistoryTests {

    @Test func historialConSeparadorDeNuevaSesion() throws {
        let previous = [VisibleTurn(role: .user, text: "ayer"), VisibleTurn(role: .assistant, text: "ok")]
        let current = [VisibleTurn(role: .user, text: "hoy", isVoice: true)]
        let messages = ChatViewModel.history(current: current, previous: previous)
        #expect(messages.map(\.text) == ["ayer", "ok", ChatViewModel.sessionDividerText, "hoy"])
        #expect(messages[2].isSessionDivider)
        #expect(messages[3].isVoice)
        // Sin sesión anterior: sin separador.
        #expect(ChatViewModel.history(current: current).map(\.text) == ["hoy"])
        #expect(ChatViewModel.history(current: []).isEmpty)

        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let loop = AgentLoop(provider: CapturingProvider([]), store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [], serverTools: [], sleep: { _ in })
        let chat = ChatViewModel(loop: loop, sessionId: try store.startSession())
        chat.loadHistory(current: [])
        #expect(chat.messages.isEmpty)
        chat.loadHistory(current: current, previous: previous)
        #expect(chat.messages.count == 4)
    }
}
