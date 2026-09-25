import Foundation
import Testing
@testable import AnimaKit

/// Smokes de TURNO COMPLETO CON TOOLS contra los providers reales — opt-in.
/// Círculo entero por el AgentLoop: user → tool_use → Sensorimotor ejecuta →
/// tool_result → el modelo responde usando el dato. Nada guionado.
@Suite struct LiveToolTurnSmokeTests {

    private func seedNote(root: URL) async throws {
        let notes = NotesTool(root: root)
        let res = await notes.execute(.object([
            "action": .string("create"), "name": .string("clave"),
            "content": .string("La palabra clave del dueño es mango-42.")]))
        try #require(!res.isError)
    }

    private func runTurn(loop: AgentLoop, sid: SessionID, text: String) async -> (tools: [String], text: String, stop: StopReason?) {
        var toolsRun: [String] = []; var streamed = ""; var stop: StopReason?
        for await event in await loop.run(sessionId: sid, userText: text) {
            switch event {
            case .toolFinished(let name, let isError): if !isError { toolsRun.append(name) }
            case .textDelta(let t): streamed += t
            case .turnFinished(let s): stop = s
            default: break
            }
        }
        return (toolsRun, streamed, stop)
    }

    @Test func claudeToolTurnSmoke() async throws {
        guard ProcessInfo.processInfo.environment["ANIMA_TOOL_SMOKE"] == "1" else { return }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".anima/test-token")
        let token = (try String(contentsOf: path, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let mode = AuthMode.detect(fromToken: token) else { return }

        let api = ProviderAPIConfig(
            baseURL: URL(string: "https://api.anthropic.com")!, version: "2023-06-01", betas: [],
            authBetas: [.oauth: ["oauth-2025-04-20", "claude-code-20250219"]],
            authSystemPrefixes: [.oauth: "You are Claude Code, Anthropic's official CLI for Claude."])
        let config = ProviderConfig(
            systemPromptBase: "Eres Anima. Usa la tool notes cuando el dueño pregunte por sus notas.",
            api: api,
            routes: [.interactive: ModelRoute(model: "claude-opus-4-8", effort: "medium", maxTokens: 2000)])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedNote(root: root)

        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let loop = AgentLoop(provider: ClaudeProvider(), store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: config), authMode: mode, token: token,
                             clientTools: [NotesTool(root: root)], serverTools: [], sleep: { _ in })
        let sid = try store.startSession()
        let r = await runTurn(loop: loop, sid: sid, text: "Lee la nota llamada 'clave' y dime cuál es la palabra clave, exacta.")
        print("[claude tool-turn] tools:", r.tools, "stop:", r.stop as Any)
        print("[claude tool-turn] texto:", r.text)
        #expect(r.tools.contains("notes"))
        #expect(r.text.lowercased().contains("mango-42"))
        #expect(r.stop == .endTurn)
    }

    @Test func onDeviceToolTurnSmoke() async throws {
        guard ProcessInfo.processInfo.environment["ANIMA_TOOL_SMOKE"] == "1" else { return }
        guard #available(iOS 26.0, macOS 26.0, *), OnDeviceAvailability.current().isAvailable else {
            print("[fm tool-turn] modelo no disponible, skip"); return }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedNote(root: root)

        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let loop = AgentLoop(provider: OnDeviceProvider.system(), store: store, telemetry: Telemetry(queue: queue),
                             router: try OnDeviceTestConfig.router(), authMode: .apiKey, token: "",
                             clientTools: [NotesTool(root: root)], serverTools: [], sleep: { _ in })
        let sid = try store.startSession()
        let r = await runTurn(loop: loop, sid: sid, text: "Lee la nota llamada 'clave' con la tool notes y dime cuál es la palabra clave, exacta.")
        print("[fm tool-turn] tools:", r.tools, "stop:", r.stop as Any)
        print("[fm tool-turn] texto:", r.text)
        #expect(r.tools.contains("notes"))
        #expect(r.text.lowercased().contains("mango"))
        #expect(r.stop == .endTurn)
    }
}
