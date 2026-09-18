import Foundation
import Testing
import GRDB
@testable import AnimaKit

/// Tool que falla siempre con el mismo error (para el eval #1 de fallo-repetido).
private struct FlakyTool: SensorimotorTool {
    var spec: ToolSpec { .client(name: "flaky", description: "una tool que siempre falla", inputSchema: .object([:])) }
    func execute(_ input: JSONValue) async -> ToolResult {
        ToolResult(content: "not found: el recurso no existe", isError: true)
    }
}

@Suite struct RealRegisterTests {

    // MARK: - PatternKey: normalización de volátiles

    @Test func volatileArgsCollapseToSameKey() {
        let a = PatternKey(toolName: "calendar",
                           argShape: PatternKey.argShape(from: .object(["date": .string("2026-01-01"),
                                                                        "id": .string(UUID().uuidString)])),
                           errorClass: "not_found", targetResource: nil).key
        let b = PatternKey(toolName: "calendar",
                           argShape: PatternKey.argShape(from: .object(["date": .string("2026-09-09"),
                                                                        "id": .string(UUID().uuidString)])),
                           errorClass: "not_found", targetResource: nil).key
        #expect(a == b)   // fechas e ids distintos colapsan → misma estrategia
    }

    @Test func differentErrorClassIsADifferentPattern() {
        let base = PatternKey.argShape(from: .object(["q": .string("hola")]))
        let notFound = PatternKey(toolName: "web", argShape: base, errorClass: "not_found", targetResource: nil).key
        let denied = PatternKey(toolName: "web", argShape: base, errorClass: "permission_denied", targetResource: nil).key
        #expect(notFound != denied)
    }

    @Test func argShapeNormalizesLeaves() {
        #expect(PatternKey.argShape(from: .string("2026-09-17")) == "<date>")
        #expect(PatternKey.argShape(from: .string(UUID().uuidString)) == "<id>")
        #expect(PatternKey.argShape(from: .int(42)) == "<n>")
        #expect(PatternKey.argShape(from: .string("hola mundo")) == "<text>")
        #expect(PatternKey.argShape(from: .string("Documents/notes/idea.txt")).hasPrefix("<path:"))
    }

    // MARK: - Insistencia y demanda

    private func makeRegister() throws -> (RealRegister, DatabaseQueue) {
        let queue = try AnimaDatabase.temporary()
        return (RealRegister(queue: queue), queue)
    }

    private func failure(session: String, now: Date = Date()) -> Failure {
        .tool(name: "flaky", input: .object(["q": .string("x")]),
              result: ToolResult(content: "not found: nada", isError: true),
              sessionId: session, now: now)
    }

    @Test func crossingThresholdMarksDemandingAndEnqueues() async throws {
        let (register, _) = try makeRegister()
        let key = PatternKey(toolName: "flaky",
                             argShape: PatternKey.argShape(from: .object(["q": .string("x")])),
                             errorClass: "not_found", targetResource: nil)

        await register.record(failure(session: "s1"))
        await register.record(failure(session: "s1"))
        #expect(await register.demand().isEmpty)          // aún bajo umbral (N=3)

        await register.record(failure(session: "s1"))     // 3ª → demanding
        let demands = await register.demand()
        #expect(demands.count == 1)
        #expect(demands.first?.toolName == "flaky")
        #expect(await register.status(key) == "demanding")
    }

    @Test func resolvedPatternReopensOnRecurrence() async throws {
        let (register, _) = try makeRegister()
        let key = PatternKey(toolName: "flaky",
                             argShape: PatternKey.argShape(from: .object(["q": .string("x")])),
                             errorClass: "not_found", targetResource: nil)
        for _ in 0..<3 { await register.record(failure(session: "s1")) }
        await register.resolve(patternKey: key.key)
        #expect(await register.status(key) == "resolved")
        #expect(await register.demand().isEmpty)

        // Reincide: el patrón se reabre.
        await register.record(failure(session: "s2"))
        #expect(await register.status(key) != "resolved")
    }

    // MARK: - Eval #1 (fallo-repetido): 3 fallos → restructure + lección

    @Test func repeatedFailureTriggersRestructureThenResolves() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let telemetry = Telemetry(queue: queue)
        let router = ModelRouter(config: try TestConfig.providerConfig())
        let realRegister = RealRegister(queue: queue)

        let toolRound: [ProviderEvent] = [
            .messageStart(id: "m", model: "claude-opus-4-8"),
            .toolUseStart(id: "t", name: "flaky"),
            .toolUseInputDelta(#"{"q":"x"}"#),
            .blockStop(index: 0),
            .messageDelta(stopReason: .toolUse, usage: Usage(inputTokens: 10, outputTokens: 5)),
            .messageStop,
        ]
        let endRound: [ProviderEvent] = [
            .messageStart(id: "m", model: "claude-opus-4-8"),
            .textDelta("no pude, lo dejo"),
            .blockStop(index: 0),
            .messageDelta(stopReason: .endTurn, usage: Usage(inputTokens: 10, outputTokens: 2)),
            .messageStop,
        ]
        // 3 turnos que llaman la tool fallida (2 rondas c/u) + 1 turno post-restructure.
        let provider = CapturingProvider([toolRound, endRound, toolRound, endRound, toolRound, endRound, endRound])
        let loop = AgentLoop(
            provider: provider, store: store, telemetry: telemetry, router: router,
            authMode: .apiKey, token: "sk-ant-api03-x",
            clientTools: [FlakyTool()], serverTools: [],
            realRegister: realRegister, sleep: { _ in })
        let sid = try store.startSession()

        for _ in 0..<3 {
            for await _ in await loop.run(sessionId: sid, userText: "usa la tool flaky") {}
        }
        // Tras 3 fallos idénticos, el patrón demanda una reestructuración.
        #expect(await realRegister.demand().count == 1)

        // El 4º turno se rutea a .restructure con el banner de autoridad inyectado.
        for await _ in await loop.run(sessionId: sid, userText: "intenta de nuevo") {}
        let last = try #require(provider.captures.value.last)
        #expect(last.route.effort == "high")           // .restructure (Opus effort high)
        let hasBanner = last.messages.contains { msg in
            msg.role == .system && msg.content.contains { block in
                if case .text(let t) = block { return t.hasPrefix("[RESTRUCTURE]") } else { return false }
            }
        }
        #expect(hasBanner)

        // El ciclo del Consolidator convierte la demanda en una lección kind=lesson
        // y marca el patrón resuelto.
        let brain = Brain(queue: queue, embedder: Embedder(forceFallback: true))
        let consolidator = Consolidator(
            brain: brain, queue: queue, provider: ScriptedProvider([]),
            router: try .haikuAll(), authMode: .apiKey, token: "x",
            realRegister: realRegister)
        let report = try await consolidator.cycle()
        #expect(report.completed)

        let lessons = try await brain.browse().filter { $0.kind == .lesson }
        #expect(lessons.count == 1)
        #expect(lessons.first?.content.contains("flaky") == true)
        #expect(await realRegister.demand().isEmpty)    // resuelto
    }
}
