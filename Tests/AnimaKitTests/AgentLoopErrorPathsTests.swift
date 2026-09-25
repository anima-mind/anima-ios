import Foundation
import Testing
@testable import AnimaKit

/// Provider que emite `events` y luego falla con `error`, contando las llamadas.
final class FailingProvider: Provider, @unchecked Sendable {
    let events: [ProviderEvent]
    let error: any Error & Sendable
    let calls = Locked(0)
    init(events: [ProviderEvent] = [], error: any Error & Sendable) {
        self.events = events
        self.error = error
    }
    func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        calls.mutate { $0 += 1 }
        let events = self.events, error = self.error
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish(throwing: error)
        }
    }
}

@Suite struct AgentLoopErrorPathsTests {

    private func run(_ provider: Provider, realRegister: RealRegister? = nil,
                     selector: ProviderSelector? = nil) async throws -> [LoopEvent] {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let loop: AgentLoop
        if let selector {
            loop = AgentLoop(selector: selector, store: store, telemetry: Telemetry(queue: queue),
                             clientTools: [], sleep: { _ in })
        } else {
            loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()),
                             authMode: .apiKey, token: "sk-ant-api03-xyz", clientTools: [],
                             retryPolicy: RetryPolicy(maxAttempts: 2), realRegister: realRegister,
                             sleep: { _ in })
        }
        let sid = try store.startSession()
        var events: [LoopEvent] = []
        for await event in await loop.run(sessionId: sid, userText: "hola") { events.append(event) }
        return events
    }

    @Test func persistentContextOverflowGivesUpAfterOneRelief() async throws {
        let provider = FailingProvider(error: ClassifiedError.contextOverflow)
        let events = try await run(provider)
        #expect(events.last == .error("Contexto excedido aún tras aliviar la presión."))
        #expect(provider.calls.value == 2)  // original + un reintento tras aliviar
    }

    @Test func fatalProviderErrorIsRegisteredInTheReal() async throws {
        let queue = try AnimaDatabase.temporary()
        let real = RealRegister(queue: queue)
        let error = ClassifiedError.fatal(status: 401, message: "invalid x-api-key")
        let events = try await run(FailingProvider(error: error), realRegister: real)
        #expect(events.last == .error("Error 401: invalid x-api-key"))
        let key = Failure.classified(toolName: "provider", error: error, sessionId: nil, now: Date()).pattern
        #expect(await real.insistence(key) == 1)
    }

    @Test func exhaustedRateLimitRetriesSurfaceReadableError() async throws {
        let provider = FailingProvider(error: ClassifiedError.rateLimited(after: 2))
        let events = try await run(provider)
        #expect(events.last == .error("Límite de tasa (retry-after 2.0s)."))
        #expect(provider.calls.value == 2)
    }

    @Test func failureAfterStreamedTextIsNotRetried() async throws {
        // Ya se mostraron deltas: reintentar duplicaría el texto → fatal sin retry.
        let provider = FailingProvider(events: [.messageStart(id: "m", model: "claude-opus-4-8"), .textDelta("Hol")],
                                       error: ClassifiedError.retryable(after: nil))
        let events = try await run(provider)
        #expect(events.contains(.textDelta("Hol")))
        #expect(events.last == .error("Error -1: Error transitorio (reintentar en 0.0s)."))
        #expect(provider.calls.value == 1)
    }

    @Test func onDeviceFailureMessagePassesThroughVerbatim() {
        let msg = OnDeviceAvailability.appleIntelligenceOff.reason!
        #expect(AgentLoop.describe(.fatal(status: OnDeviceProvider.unavailableStatus, message: msg)) == msg)
        #expect(AgentLoop.describe(.contextOverflow) == "Contexto excedido.")
    }

    @Test func unclassifiedErrorsUseLocalizedDescription() async throws {
        let events = try await run(FailingProvider(error: StoreFailure(message: "algo raro")))
        #expect(events.last == .error("algo raro"))
    }

    @Test func modeWithoutCortexExplainsMissingModel() async throws {
        let selector = ProviderSelector(mode: .claude, claude: nil, local: nil, availability: { .available })
        let events = try await run(MockProvider(events: []), selector: selector)
        guard case .error(let message)? = events.last else { Issue.record("sin error"); return }
        #expect(message.contains("no tiene un modelo configurado"))
    }
}
