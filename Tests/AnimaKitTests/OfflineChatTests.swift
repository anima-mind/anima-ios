import Foundation
import GRDB
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

    static func remoteLoop(_ provider: Provider, store: SymbolicStore, queue: DatabaseQueue) throws -> AgentLoop {
        AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                  router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                  token: "sk-ant-api03-xyz", clientTools: [], serverTools: [], sleep: { _ in })
    }

    @Test func networkBackMidTurnSendsTheQueuedTurnWhenItEnds() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let provider = GatedProvider(.text("Listo."))
        let chat = ChatViewModel(loop: try Self.remoteLoop(provider, store: store, queue: queue),
                                 sessionId: try store.startSession())
        chat.usesRemoteConversation = true
        await chat.setOffline(true)
        chat.input = "hola"
        await chat.send()
        #expect(chat.hasQueuedTurn)

        // Pasa a Solo teléfono y conversa sin red; la red vuelve a mitad del turno.
        chat.usesRemoteConversation = false
        chat.input = "otra"
        let turn = Task { await chat.send() }
        await provider.waitUntilCalled()
        #expect(chat.isStreaming)
        await chat.setOffline(false)
        #expect(chat.hasQueuedTurn)

        provider.release()
        await turn.value
        #expect(!chat.hasQueuedTurn && !chat.isStreaming)
        #expect(chat.messages.filter { $0.role == .assistant && $0.text == "Listo." }.count == 2)
    }

    @Test func retryWhileOfflineQueuesInsteadOfFailingAgain() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let provider = FailingProvider(error: ClassifiedError.fatal(status: 500, message: "caído"))
        let chat = ChatViewModel(loop: try Self.remoteLoop(provider, store: store, queue: queue),
                                 sessionId: try store.startSession())
        chat.usesRemoteConversation = true
        chat.input = "hola"
        await chat.send()
        #expect(chat.messages.last?.isError == true)
        let calls = provider.calls.value

        await chat.setOffline(true)
        await chat.retry()
        #expect(provider.calls.value == calls)
        #expect(chat.hasQueuedTurn)
        #expect(chat.messages.last?.text == ChatViewModel.offlineQueuedNote)
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
    }
}
