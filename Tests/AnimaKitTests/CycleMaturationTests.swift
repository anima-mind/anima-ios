import Foundation
import Testing
import GRDB
@testable import AnimaKit

// Campo batch 3 / FIX C: el ciclo nocturno corrió en producción pero el Mind
// sheet decía "0 noches" y SelfModel.cycles=0. Raíz: el shell creaba el
// ChatViewModel SIN selfModel (loadMind salía temprano → MindState default
// p 1.00 / 0 ciclos para siempre), y un lanzamiento en background del BGTask no
// cableaba el harness (holder vacío). Un solo origen de verdad: SelfModel.cycles.

@Suite("Campo — el ciclo madura n y el Mind sheet lo lee")
struct CycleMaturationTests {

    static let reflection = [ProviderEvent].text(#"{"summary":"nada nuevo","insights":[]}"#)

    static func harness(_ scripts: [[ProviderEvent]]) throws -> (Consolidator, SelfModel, DatabaseQueue) {
        let queue = try AnimaDatabase.temporary()
        let brain = Brain(queue: queue, embedder: Embedder(forceFallback: true))
        let selfModel = SelfModel(queue: queue)
        let consolidator = Consolidator(brain: brain, queue: queue, provider: ScriptedProvider(scripts),
                                        router: try .haikuAll(), authMode: .apiKey, token: "sk-ant-api03-x",
                                        selfModel: selfModel)
        return (consolidator, selfModel, queue)
    }

    @Test func elCaminoDelSchedulerMaduraYPersiste() async throws {
        let (consolidator, selfModel, queue) = try Self.harness([Self.reflection])
        let holder = ConsolidatorHolder()
        holder.set(consolidator, scheduler: SleepScheduler())
        #expect(await holder.run(isExpired: { false }))
        #expect(await selfModel.cycles() == 1)
        // Persistido: otra instancia sobre la misma DB (como al reabrir la app) lo lee.
        #expect(await SelfModel(queue: queue).cycles() == 1)
    }

    @Test func cicloInterrumpidoNoMaduraHastaCompletar() async throws {
        let (consolidator, selfModel, _) = try Self.harness([Self.reflection])
        #expect(await SleepScheduler().runResumable(consolidator, isExpired: { true }) == false)
        #expect(await selfModel.cycles() == 0)
        #expect(await SleepScheduler().runResumable(consolidator))
        #expect(await selfModel.cycles() == 1)
    }

    @Test func simularUnaNocheMaduraPorLaMismaRuta() async throws {
        let (consolidator, selfModel, _) = try Self.harness([Self.reflection, Self.reflection])
        _ = await NightSimulator(consolidator: consolidator).run()
        _ = await NightSimulator(consolidator: consolidator).run()
        #expect(await selfModel.cycles() == 2)
    }

    @Test func disparadoresSimultaneosSeCoalescenEnUnCiclo() async throws {
        let queue = try AnimaDatabase.temporary()
        let selfModel = SelfModel(queue: queue)
        let gate = GatedProvider(.text("[]"))
        let consolidator = Consolidator(brain: Brain(queue: queue, embedder: Embedder(forceFallback: true)),
                                        queue: queue, provider: gate, router: try .haikuAll(),
                                        authMode: .apiKey, token: "sk-ant-api03-x", selfModel: selfModel)
        try ConsolidationInbox(queue: queue).enqueue(sessionId: "s1", text: "Vivo en Bogota.")
        // El primero queda colgado en el destilado (provider retenido)…
        let first = Task { try await consolidator.cycle() }
        await gate.waitUntilCalled()
        // …y el segundo (otro disparador) llega mientras tanto: se coalesce.
        let second = Task { try await consolidator.cycle() }
        try await Task.sleep(nanoseconds: 50_000_000)
        gate.release()
        let (ra, rb) = (try await first.value, try await second.value)
        #expect(ra.cycle == rb.cycle)
        #expect(await selfModel.cycles() == 1)
    }

    #if canImport(SwiftUI)
    @MainActor
    @Test func elMindSheetLeeLosCiclosDelSelfModel() async throws {
        let (consolidator, selfModel, queue) = try Self.harness([Self.reflection])
        _ = try await consolidator.cycle()
        let store = SymbolicStore(queue: queue)
        let loop = AgentLoop(provider: MockProvider(events: []), store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [], serverTools: [], sleep: { _ in })
        let chat = ChatViewModel(loop: loop, sessionId: try store.startSession(), selfModel: selfModel)
        await chat.loadMind()
        #expect(chat.mind.cycles == 1)
        #expect(chat.mind.p == Plasticity.value(cycles: 1))
    }
    #endif
}

/// Provider que retiene la respuesta hasta `release()` (para modelar un ciclo largo).
final class GatedProvider: Provider, @unchecked Sendable {
    private let events: [ProviderEvent]
    private let lock = NSLock()
    private var called = false
    private var released = false

    init(_ events: [ProviderEvent]) { self.events = events }

    func release() { lock.lock(); released = true; lock.unlock() }
    private var isReleased: Bool { lock.lock(); defer { lock.unlock() }; return released }
    private var wasCalled: Bool { lock.lock(); defer { lock.unlock() }; return called }

    func waitUntilCalled() async {
        while !wasCalled { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        lock.lock(); called = true; lock.unlock()
        let events = self.events
        return AsyncThrowingStream { continuation in
            Task {
                while !self.isReleased { try? await Task.sleep(nanoseconds: 5_000_000) }
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}
