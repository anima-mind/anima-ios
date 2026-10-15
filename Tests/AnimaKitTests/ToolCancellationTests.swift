import Foundation
import GRDB
import Testing
@testable import AnimaKit

/// Tool cooperativa: duerme `seconds` revisando la cancelación; si la cortan,
/// no escribe.
private struct CooperativeTool: SensorimotorTool {
    let seconds: Double
    let wrote = Locked(0)
    let sawCancel = Locked(false)
    var spec: ToolSpec {
        .client(name: "coop_read", description: "lee", inputSchema: .object(["type": .string("object")]))
    }
    func execute(_ input: JSONValue) async -> ToolResult {
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            sawCancel.mutate { $0 = true }
            return ToolResult(content: "cancelled", isError: true)
        }
        wrote.mutate { $0 += 1 }
        return ToolResult(content: "ok")
    }
}

/// Tool que IGNORA la cancelación (tarda `delay` pase lo que pase).
private struct DeafTool: SensorimotorTool {
    let delay: TimeInterval
    var spec: ToolSpec {
        .client(name: "deaf_read", description: "lee", inputSchema: .object(["type": .string("object")]))
    }
    func execute(_ input: JSONValue) async -> ToolResult {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { c.resume() }
        }
        return ToolResult(content: "leído")
    }
}

/// Primera llamada: pide `tool`; después del tool_result, texto.
private final class ToolThenTextProvider: Provider, @unchecked Sendable {
    let tool: String
    init(tool: String) { self.tool = tool }
    func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        let last = ctx.messages.last(where: { $0.role == .user })?.content ?? []
        let afterTool = last.contains { if case .toolResult = $0 { return true }; return false }
        let text = last.compactMap { block -> String? in if case .text(let t) = block { return t }; return nil }.joined()
        let events: [ProviderEvent]
        if afterTool || text.contains("sin tool") {
            events = [.messageStart(id: "t", model: "x"), .textDelta("Listo."), .blockStop(index: 0),
                      .messageDelta(stopReason: .endTurn, usage: Usage()), .messageStop]
        } else {
            events = [.messageStart(id: "u", model: "x"), .toolUseStart(id: "toolu_\(UUID().uuidString.prefix(6))", name: tool),
                      .toolUseInputDelta("{}"), .blockStop(index: 0),
                      .messageDelta(stopReason: .toolUse, usage: Usage()), .messageStop]
        }
        return AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            c.finish()
        }
    }
}

@Suite("Review #38 ronda 6 — la cancelación del turno llega a la tool")
struct ToolCancellationTests {
    private func loop(_ tool: any SensorimotorTool, _ store: SymbolicStore, _ queue: DatabaseQueue) throws -> AgentLoop {
        AgentLoop(provider: ToolThenTextProvider(tool: tool.spec.name), store: store, telemetry: Telemetry(queue: queue),
                  router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                  token: "sk-ant-api03-xyz", clientTools: [tool], serverTools: [],
                  permissionPolicy: .app(ownerAllowlist: { [] }), sleep: { _ in })
    }

    // MAYOR: tool cooperativa de 3 s, turno cancelado a los 100 ms → vuelve ya,
    // con el resultado de cancelación, la tool ve la cancelación y no escribe.
    @Test func cancelarElTurnoCortaLaTool() async throws {
        let tool = CooperativeTool(seconds: 3)
        let sensorimotor = Sensorimotor(tools: [tool], policy: .app(ownerAllowlist: { [] }))
        let start = ContinuousClock.now
        let call = Task { await sensorimotor.execute(name: "coop_read", input: .object([:])) }
        try await Task.sleep(for: .milliseconds(100))
        call.cancel()
        let result = await call.value
        #expect(ContinuousClock.now - start < .milliseconds(1500))
        #expect(result.isError)
        #expect(result.content == Sensorimotor.cancelledResult("coop_read").content)
        #expect(await eventually { tool.sawCancel.value })
        try await Task.sleep(for: .seconds(3.2))
        #expect(tool.wrote.value == 0)
    }

    @Test func yaCanceladoNiArrancaLaTool() async {
        let tool = CooperativeTool(seconds: 3)
        let sensorimotor = Sensorimotor(tools: [tool], policy: .app(ownerAllowlist: { [] }))
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await sensorimotor.execute(name: "coop_read", input: .object([:]))
        }
        let result = await call.value
        #expect(result.content == Sensorimotor.cancelledResult("coop_read").content)
        #expect(tool.wrote.value == 0)
    }

    // En el loop: el turno A (cancelado con la tool en curso) no retiene la
    // sesión 3 s; el B de la misma sesión corre ya y la tool no escribe.
    @Test func elTurnoCanceladoNoRetieneLaSesion() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let tool = CooperativeTool(seconds: 3)
        let loop = try loop(tool, store, queue)
        let sid = try store.startSession()
        let a = Task {
            for await event in await loop.run(sessionId: sid, content: [.text("A")], surface: .glassesHUD) {
                if case .toolStarted = event { try? await Task.sleep(for: .milliseconds(100)); return }
            }
        }
        await a.value
        let start = ContinuousClock.now
        var reply = ""
        for await event in await loop.run(sessionId: sid, content: [.text("B sin tool")]) {
            if case .textDelta(let d) = event { reply += d }
        }
        #expect(reply == "Listo.")
        #expect(ContinuousClock.now - start < .milliseconds(1500))
        #expect(tool.wrote.value == 0)
        #expect(SessionSerializationTests.paired(try store.window(sessionId: sid)))
    }

    // MEDIO: un turno cancelado mientras espera en la cola no corre ni persiste.
    @Test func elTurnoCanceladoEnLaColaNoPersiste() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let loop = try loop(DeafTool(delay: 0.4), store, queue)
        let sid = try store.startSession()
        let a = Task {
            for await _ in await loop.run(sessionId: sid, content: [.text("A")], surface: .glassesHUD) {}
        }
        try await Task.sleep(for: .milliseconds(30))
        let b = Task {
            for await _ in await loop.run(sessionId: sid, content: [.text("B esperando")]) {}
        }
        try await Task.sleep(for: .milliseconds(50))
        b.cancel()
        await b.value
        await a.value
        await loop.waitUntilIdle()
        let texts = try store.window(sessionId: sid).flatMap(\.content).compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }
        #expect(texts.contains("A"))
        #expect(!texts.contains("B esperando"))
        #expect(await loop.turnsInFlight == 0)
    }

    // MENOR: tras un timeout el modelo lee que la acción pudo completarse.
    @Test func elTimeoutAvisaQueLaAccionPudoCompletarse() async {
        let text = Sensorimotor.timeoutResult("calendar", timeout: 30).content
        #expect(text.contains("excedió el timeout de 30s"))
        #expect(text.contains("pudo haberse completado"))
        #expect(text.contains("verifica su estado antes de reintentarla"))
        let sensorimotor = Sensorimotor(tools: [DeafTool(delay: 30)], policy: .app(ownerAllowlist: { [] }), timeout: 0.1)
        let result = await sensorimotor.execute(name: "deaf_read", input: .object([:]))
        #expect(result.content == Sensorimotor.timeoutResult("deaf_read", timeout: 0.1).content)
    }
}
