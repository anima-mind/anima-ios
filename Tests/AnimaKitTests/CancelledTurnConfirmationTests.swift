import Foundation
import GRDB
import Testing
@testable import AnimaKit

/// Lectura cooperativa (se corta al cancelar).
private struct SlowRead: SensorimotorTool {
    var spec: ToolSpec {
        .client(name: "slow_read", description: "lee", inputSchema: .object(["type": .string("object")]))
    }
    func execute(_ input: JSONValue) async -> ToolResult {
        // 60 s: un runner lento jamás la ve terminar antes de la cancelación.
        try? await Task.sleep(for: .seconds(60))
        return ToolResult(content: "leído")
    }
}

/// Eferente: pide confirmación; registra si llegó a escribir.
private struct Write: SensorimotorTool {
    let wrote: Locked<Int>
    var spec: ToolSpec {
        .client(name: "write_note", description: "escribe", inputSchema: .object(["type": .string("object")]))
    }
    func kind(for input: JSONValue) -> ToolKind { .efferent }
    func execute(_ input: JSONValue) async -> ToolResult {
        wrote.mutate { $0 += 1 }
        return ToolResult(content: "escrito")
    }
}

/// Un mensaje con las tools pedidas (en orden); tras los resultados, texto.
private final class ToolsProvider: Provider, @unchecked Sendable {
    let tools: [String]
    init(_ tools: [String]) { self.tools = tools }
    func complete(_ ctx: AssembledContext, tools specs: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        let last = ctx.messages.last(where: { $0.role == .user })?.content ?? []
        let afterTool = last.contains { if case .toolResult = $0 { return true }; return false }
        let plain = last.contains { if case .text(let t) = $0 { return t.contains("sin tools") }; return false }
        var events: [ProviderEvent] = [.messageStart(id: UUID().uuidString, model: "x")]
        if afterTool || plain {
            events += [.textDelta("Listo."), .blockStop(index: 0), .messageDelta(stopReason: .endTurn, usage: Usage())]
        } else {
            for (i, name) in tools.enumerated() {
                events += [.toolUseStart(id: "toolu_\(i)_\(UUID().uuidString.prefix(4))", name: name),
                           .toolUseInputDelta("{}"), .blockStop(index: i)]
            }
            events += [.messageDelta(stopReason: .toolUse, usage: Usage())]
        }
        events.append(.messageStop)
        return AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            c.finish()
        }
    }
}

/// ¿Terminó la tarea dentro del tope? Sin esperarla si no (un turno colgado
/// en un sheet hace fallar el test en vez de colgar la suite).
func finishes(_ task: Task<Void, Never>, within limit: Duration) async -> Bool {
    let done = Locked(false)
    let (signal, wake) = AsyncStream<Void>.makeStream()
    Task {
        await task.value
        done.mutate { $0 = true }
        wake.finish()
    }
    Task {
        try? await Task.sleep(for: limit)
        wake.finish()
    }
    for await _ in signal {}
    return done.value
}

@MainActor
@Suite("Review #38 ronda 7 — un turno cancelado no pide confirmación ni retiene la sesión")
struct CancelledTurnConfirmationTests {
    private struct Rig {
        let loop: AgentLoop
        let store: SymbolicStore
        let queue: DatabaseQueue
        let center: ConfirmationCenter
        let wrote: Locked<Int>
        let sid: SessionID
    }

    private func rig(_ tools: [String]) throws -> Rig {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let center = ConfirmationCenter()
        let wrote = Locked(0)
        let loop = AgentLoop(provider: ToolsProvider(tools), store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [SlowRead(), Write(wrote: wrote)],
                             serverTools: [], permissionPolicy: .app(ownerAllowlist: { [] }),
                             confirmation: center, realRegister: RealRegister(queue: queue), sleep: { _ in })
        return Rig(loop: loop, store: store, queue: queue, center: center, wrote: wrote, sid: try store.startSession())
    }

    // Cancelado durante la lectura: la eferente del mismo mensaje NO abre el sheet.
    @Test func canceladoAntesNoAbreElSheet() async throws {
        let r = try rig(["slow_read", "write_note"])
        let turn = Task {
            for await _ in await r.loop.run(sessionId: r.sid, content: [.text("lee y escribe")], surface: .glassesHUD) {}
        }
        try await Task.sleep(for: .milliseconds(100))
        turn.cancel()
        #expect(await finishes(turn, within: .seconds(20)))
        // El turno cancelado termina de verdad (no queda esperando un sheet).
        let idle = await finishes(Task { await r.loop.waitUntilIdle() }, within: .seconds(20))
        #expect(idle)
        #expect(r.center.pending == nil)
        guard idle else { r.center.resolve(false); return }
        #expect(r.wrote.value == 0)
        #expect(SessionSerializationTests.paired(try r.store.window(sessionId: r.sid)))
    }

    // Cancelado con el sheet abierto: el sheet se cierra, el turno termina y la
    // sesión no queda retenida.
    @Test func canceladoConElSheetAbiertoLoCierra() async throws {
        let r = try rig(["write_note"])
        let turn = Task {
            for await _ in await r.loop.run(sessionId: r.sid, content: [.text("escribe")], surface: .glassesHUD) {}
        }
        #expect(await eventually { await MainActor.run { r.center.pending != nil } })
        turn.cancel()
        #expect(await finishes(turn, within: .seconds(20)))
        #expect(await eventually { await MainActor.run { r.center.pending == nil } })
        if r.center.pending != nil { r.center.resolve(false) }
        #expect(await finishes(Task { await r.loop.waitUntilIdle() }, within: .seconds(20)))
        #expect(await r.loop.turnsInFlight == 0)
        #expect(r.wrote.value == 0)
        var reply = ""
        for await event in await r.loop.run(sessionId: r.sid, content: [.text("hola sin tools")]) {
            if case .textDelta(let d) = event { reply += d }
        }
        #expect(reply == "Listo.")
        #expect(SessionSerializationTests.paired(try r.store.window(sessionId: r.sid)))
    }

    @Test func elCentroCierraElSheetAlCancelar() async {
        let center = ConfirmationCenter()
        let ask = Task {
            await center.confirm(ConfirmationRequest(tool: "calendar", operation: "create", summary: "x", input: .null))
        }
        #expect(await eventually { await MainActor.run { center.pending != nil } })
        ask.cancel()
        let answered = Locked<Bool?>(nil)
        let waiter = Task { answered.mutate { $0 = nil }; let v = await ask.value; answered.mutate { $0 = v } }
        #expect(await finishes(waiter, within: .seconds(20)))
        #expect(answered.value == false)
        #expect(await eventually { await MainActor.run { center.pending == nil } })
        if center.pending != nil { center.resolve(false) }
        // El siguiente puede pedir de nuevo (no quedó una continuación colgada).
        let next = Task {
            await center.confirm(ConfirmationRequest(tool: "calendar", operation: "create", summary: "y", input: .null))
        }
        #expect(await eventually { await MainActor.run { center.pending?.summary == "y" } })
        center.resolve(true)
        #expect(await next.value)
    }

    // MEDIO 2b: tres cancelaciones del dueño no dejan fallos ni patrón.
    @Test func tresCancelacionesNoGeneranPatron() async throws {
        let r = try rig(["slow_read"])
        for _ in 0..<3 {
            let turn = Task {
                for await _ in await r.loop.run(sessionId: r.sid, content: [.text("lee")], surface: .glassesHUD) {}
            }
            try await Task.sleep(for: .milliseconds(80))
            turn.cancel()
            await turn.value
            await r.loop.waitUntilIdle()
        }
        let failures = try await r.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM real_failure") }
        let patterns = try await r.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM real_pattern") }
        #expect(failures == 0)
        #expect(patterns == 0)
    }
}

@Suite("Review #38 ronda 7 — textos honestos y marcador de cancelación")
struct CancellationTextTests {
    @Test func laCancelacionAvisaQuePudoCompletarseYEsMarcada() {
        let cut = Sensorimotor.cancelledResult("calendar")
        #expect(cut.content.contains("pudo haberse completado"))
        #expect(cut.content.contains("verifica su estado antes de reintentarla"))
        #expect(cut.isCancellation)
        #expect(!cut.isRejection)
        let notStarted = Sensorimotor.notStartedResult("calendar")
        #expect(notStarted.content.contains("no se ejecutó"))
        #expect(notStarted.isCancellation)
    }

    @Test func elTimeoutMuestraDecimales() {
        #expect(Sensorimotor.seconds(30) == "30s")
        #expect(Sensorimotor.seconds(0.1) == "0.1s")
        #expect(Sensorimotor.seconds(1.5) == "1.5s")
        #expect(Sensorimotor.seconds(0.5) == "0.5s")
        #expect(!Sensorimotor.timeoutResult("x", timeout: 0.1).content.contains("0s."))
    }
}

@MainActor
@Suite("Review #38 ronda 7 — turno espejado que se canceló en la cola")
struct DroppedMirrorTests {
    @Test func elChatQuitaLaPreguntaQueNoCorrio() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let chat = ChatViewModel(loop: try FullHistoryStoreTests.loop(store, queue), sessionId: try store.startSession())
        await chat.render(.userTurn(text: "¿qué tengo?", origin: .glassesHUD))
        #expect(chat.isStreaming)
        await chat.render(.turnDropped(origin: .glassesHUD))
        #expect(chat.messages.isEmpty)
        #expect(!chat.isStreaming)
    }

    @Test func siriCortadaEnLaColaSoltaSuPregunta() async {
        let spy = SiriSpy()
        // Un runner que jamás saca el turno de la cola (nunca emite .started).
        struct QueuedForever: TurnRunner {
            func run(sessionId: SessionID, content: [ContentBlock], surface: SurfaceID) async -> AsyncStream<LoopEvent> {
                AsyncStream { _ in }
            }
        }
        let siri = spy.runner(QueuedForever(), deadline: .milliseconds(20), hardLimit: .milliseconds(60))
        #expect(await siri.ask("hola") == .deferred)
        await siri.release()
        await spy.waitSettled()
        #expect(spy.delivered.value.last == .turnDropped(origin: .siri))
        #expect(spy.settled.value == [.failed(SiriTurn.timeoutText)])
    }
}
