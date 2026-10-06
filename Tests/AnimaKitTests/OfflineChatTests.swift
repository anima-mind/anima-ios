import Foundation
import Testing
@testable import AnimaKit

// Batch 5b #7: sin red, el turno a un modelo remoto se encola con aviso claro
// (no un error con "Reintentar") y sale solo al volver la conexión.

@MainActor
@Suite struct OfflineChatTests {
    @Test func queuesWhileOfflineAndSendsOnceBackOnline() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let provider = CapturingProvider([.text("Aquí estoy.")])
        let loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [], serverTools: [], sleep: { _ in })
        let chat = ChatViewModel(loop: loop, sessionId: try store.startSession())
        chat.usesRemoteConversation = true
        await chat.setOffline(true)
        await chat.setOffline(true)
        chat.input = "hola"
        await chat.send()
        #expect(chat.isOffline && chat.hasQueuedTurn)
        #expect(provider.captures.value.isEmpty)
        #expect(chat.messages.map(\.text) == ["hola", ChatViewModel.offlineQueuedNote])

        await chat.setOffline(false)
        #expect(!chat.hasQueuedTurn)
        #expect(provider.captures.value.count == 1)
        #expect(chat.messages.filter { $0.role == .user }.count == 1)       // sin burbuja duplicada
        #expect(chat.messages.last?.text == "Aquí estoy.")

        // Solo teléfono: sin red igual responde (no encola).
        chat.usesRemoteConversation = false
        await chat.setOffline(true)
        chat.input = "otra"
        await chat.send()
        #expect(!chat.hasQueuedTurn && provider.captures.value.count == 2)
    }
}
