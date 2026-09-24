import Foundation
import Testing
@testable import AnimaKit

/// Sesión local con guion por llamada: cada paso reproduce elementos o lanza.
final class SequencedOnDeviceSession: OnDeviceModelSession, @unchecked Sendable {
    enum Step { case elements([OnDeviceStreamElement]); case fail(OnDeviceSessionError) }
    private let steps: [Step]
    private let index = Locked(0)
    let requests = Locked<[OnDeviceRequest]>([])

    init(_ steps: [Step]) { self.steps = steps }

    func stream(_ request: OnDeviceRequest) -> AsyncThrowingStream<OnDeviceStreamElement, Error> {
        requests.mutate { $0.append(request) }
        let i = index.mutate { current -> Int in let c = current; current += 1; return c }
        let step = i < steps.count ? steps[i] : .elements([])
        return AsyncThrowingStream { continuation in
            switch step {
            case .elements(let elements):
                for element in elements { continuation.yield(element) }
                continuation.finish()
            case .fail(let error):
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Envuelve un provider y captura las CallOpts (relief) + messages de cada llamada.
final class OptsSpyProvider: Provider, @unchecked Sendable {
    let inner: Provider
    let reliefs = Locked<[ReliefControls]>([])
    let contexts = Locked<[[Message]]>([])
    init(_ inner: Provider) { self.inner = inner }

    func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        reliefs.mutate { $0.append(opts.relief) }
        contexts.mutate { $0.append(ctx.messages) }
        return inner.complete(ctx, tools: tools, opts: opts)
    }
}

@Suite struct ContextProfileTests {

    private func makeStore() throws -> (SymbolicStore, SessionID) {
        let store = SymbolicStore(queue: try AnimaDatabase.temporary())
        return (store, try store.startSession())
    }

    private func memories(_ n: Int) -> [ActivatedMemory] {
        (1...n).map { ActivatedMemory(id: "m\($0)", content: "recuerdo \($0)", kind: .semantic,
                                      confidence: 0.8, score: Double($0)) }
    }

    // MARK: presupuesto por provider

    @Test func profilesCarryProviderRelativeBudgets() {
        #expect(ContextProfile.onDevice.contextBudgetTokens == 4096)
        #expect(ContextProfile.claude.contextBudgetTokens == 180_000)
        #expect(ContextProfile.onDevice.maxActivatedMemories == 3)
        #expect(ContextProfile.onDevice.reliefMode == .localMechanical)
        #expect(ContextProfile.claude.reliefMode == .serverSide)
    }

    /// Misma conversación: con Claude la presión es mínima; on-device, alta.
    @Test func pressureIsRelativeToProvider() async throws {
        let (store, sid) = try makeStore()
        let text = String(repeating: "palabra ", count: 1200)   // ~2.7k tokens
        let claude = WorkingMemory(store: store, profile: .claude)
        let local = WorkingMemory(store: store, profile: .onDevice)
        _ = try await claude.assemble(.text(text, sessionId: sid))
        _ = try await local.assemble(.text(text, sessionId: sid))
        #expect(await claude.pressure < 0.05)
        #expect(await local.pressure > 0.5)
    }

    /// Golden on-device: history window corta + top-3 memorias, MISMO orden §5.1.
    @Test func onDeviceAssembleIsShortWithStableOrder() async throws {
        let (store, sid) = try makeStore()
        for i in 0..<30 {
            try store.append(sessionId: sid, message: .user("pregunta \(i) " + String(repeating: "x", count: 400)))
            try store.append(sessionId: sid, message: .assistant([.text("respuesta \(i) " + String(repeating: "y", count: 400))]))
        }
        let local = WorkingMemory(store: store, profile: .onDevice)
        await local.setActivatedMemories(memories(8))
        let messages = try await local.assemble(.text("¿y ahora?", sessionId: sid))

        let claude = WorkingMemory(store: store, profile: .claude)
        await claude.setActivatedMemories(memories(8))
        let full = try await claude.assemble(.text("¿y ahora?", sessionId: sid))

        // History recortada: se conservan solo las más recientes.
        let localHistory = messages.prefix { $0.role != .system }
        #expect(localHistory.count < 10)
        #expect(full.prefix { $0.role != .system }.count == 60)
        guard case .text(let newest)? = localHistory.last?.content.first else {
            Issue.record("history vacía"); return
        }
        #expect(newest.hasPrefix("respuesta 29"))

        // Cola estable: [system(self), user(activadas top-3), user(turn)].
        let tail = Array(messages.suffix(3))
        #expect(tail.map(\.role) == [.system, .user, .user])
        guard case .text(let block)? = tail[1].content.first else {
            Issue.record("bloque activado ausente"); return
        }
        #expect(block == WorkingMemory.activatedMemoriesHeader + "\n- recuerdo 1\n- recuerdo 2\n- recuerdo 3")
        #expect(tail[2].content == [.text("¿y ahora?")])
    }

    // MARK: relieve local

    @Test func onDeviceNeverEmitsServerSideRelief() async throws {
        let (store, sid) = try makeStore()
        let local = WorkingMemory(store: store, profile: .onDevice)
        _ = try await local.assemble(.text(String(repeating: "z", count: 40_000), sessionId: sid))
        #expect(await local.pressure > 1)
        #expect(!(await local.relieve(.compact)).isActive)
        #expect(!(await local.relieve(.clearStaleToolResults)).isActive)
        #expect(!(await local.consumeRelief()).isActive)
    }

    @Test func trimStaleToolResultsKeepsLatest() {
        let messages: [Message] = [
            .user([.toolResult(toolUseId: "a", content: "viejo", isError: false)]),
            .user([.toolResult(toolUseId: "b", content: "reciente", isError: false)]),
        ]
        let trimmed = LocalRelief.trimStaleToolResults(messages)
        #expect(trimmed[0].content == [.toolResult(toolUseId: "a", content: LocalRelief.trimmedPlaceholder, isError: false)])
        #expect(trimmed[1].content == [.toolResult(toolUseId: "b", content: "reciente", isError: false)])
    }

    @Test func shrinkHistoryEvictsOldestAndProtectsTurnTail() {
        let big = String(repeating: "h", count: 3600)   // ~1000 tokens
        let messages: [Message] = [
            .user("vieja " + big),
            .assistant([.text("respuesta vieja " + big)]),
            .user("reciente"),
            .assistant([.text("ok")]),
            Message(role: .system, content: [.text("[SELF]")]),
            .user("turno " + big),
        ]
        let (kept, evicted) = LocalRelief.shrinkHistory(messages, targetTokens: 1100)
        #expect(evicted.count == 2)
        #expect(kept.first == .user("reciente"))
        // La cola del turno jamás se desaloja, aunque siga sobre el objetivo.
        #expect(Array(kept.suffix(2)).map(\.role) == [.system, .user])
    }

    /// Overflow real en on-device: relieve mecánico local + reintento, SIN betas
    /// de compaction/context-management en ningún request, y lo desalojado al inbox.
    @Test func overflowTriggersLocalReliefWithoutBetas() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let sid = try store.startSession()
        let big = String(repeating: "x", count: 1500)
        for i in 0..<3 {
            try store.append(sessionId: sid, message: .user("p\(i) " + big))
            try store.append(sessionId: sid, message: .assistant([.text("r\(i) " + big)]))
        }
        let inbox = ConsolidationInbox(queue: queue)
        let session = SequencedOnDeviceSession([
            .fail(.exceededContextWindow),
            .elements([.snapshot("Listo.")]),
        ])
        let spy = OptsSpyProvider(OnDeviceProvider(session: session, availability: { .available }))
        let loop = AgentLoop(
            provider: spy, store: store, telemetry: Telemetry(queue: queue),
            router: try OnDeviceTestConfig.router(), authMode: .apiKey, token: "",
            clientTools: [], serverTools: [],
            workingMemory: WorkingMemory(store: store, profile: .onDevice),
            inbox: inbox, sleep: { _ in })

        var events: [LoopEvent] = []
        for await event in await loop.run(sessionId: sid, userText: "hola") { events.append(event) }

        #expect(events.contains(.turnFinished(stopReason: .endTurn)))
        #expect(spy.reliefs.value.count == 2)
        #expect(spy.reliefs.value.allSatisfy { !$0.isActive })   // jamás betas de Anthropic
        let contexts = spy.contexts.value
        #expect(LocalRelief.estimateTokens(contexts[1]) < LocalRelief.estimateTokens(contexts[0]))
        // El turno del dueño siempre sobrevive al relieve.
        #expect(contexts[1].last == .user("hola"))
        // Lo desalojado se encoló al Brain (evict), además del turno del dueño.
        let sources = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT source FROM consolidation_inbox")
        }
        #expect(sources.contains("evict"))
    }
}
