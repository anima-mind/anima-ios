import Foundation
import Testing
@testable import AnimaKit

/// Smoke de RUTEO contra Claude real — opt-in (ANIMA_PROACTIVE_SMOKE=1, token en
/// ~/.anima/test-token; jamás se imprime). Specs reales de anima_reminders,
/// calendar y reminders; las ejecuciones de agenda son stubs y TODO eferente se
/// rechaza en la confirmación (se captura el input, nada se escribe).
@Suite struct LiveProactiveSmokeTests {

    final class CapturingConfirmation: ConfirmationProvider, @unchecked Sendable {
        let requests = Locked<[ConfirmationRequest]>([])
        func confirm(_ request: ConfirmationRequest) async -> Bool {
            requests.mutate { $0.append(request) }
            return false
        }
    }

    /// Spec y clasificación de la tool real; ejecución canned (sin EventKit).
    struct StubbedTool: SensorimotorTool {
        let real: any SensorimotorTool
        var spec: ToolSpec { real.spec }
        func kind(for input: JSONValue) -> ToolKind { real.kind(for: input) }
        func confirmationSummary(for input: JSONValue) -> String { real.confirmationSummary(for: input) }
        func execute(_ input: JSONValue) async -> ToolResult { ToolResult(content: "Sin eventos ni recordatorios.") }
    }

    private func turn(_ text: String, token: String, mode: AuthMode) async throws -> [ConfirmationRequest] {
        let api = ProviderAPIConfig(
            baseURL: URL(string: "https://api.anthropic.com")!, version: "2023-06-01", betas: [],
            authBetas: [.oauth: ["oauth-2025-04-20", "claude-code-20250219"]],
            authSystemPrefixes: [.oauth: "You are Claude Code, Anthropic's official CLI for Claude."])
        let config = ProviderConfig(
            systemPromptBase: "Eres Anima, una mente personal que vive en el teléfono del dueño. Responde breve, en español. Usa tus herramientas cuando el dueño te pida algo que ellas resuelven.",
            api: api,
            routes: [.interactive: ModelRoute(model: "claude-opus-4-8", effort: "medium", maxTokens: 2000)])
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let confirmation = CapturingConfirmation()
        let tools: [any SensorimotorTool] = [
            AnimaRemindersTool(store: AnimaReminderStore(queue: queue)),
            StubbedTool(real: CalendarTool()),
            StubbedTool(real: RemindersTool()),
        ]
        let loop = AgentLoop(provider: ClaudeProvider(), store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: config), authMode: mode, token: token,
                             clientTools: tools, serverTools: [], confirmation: confirmation, sleep: { _ in })
        let sid = try store.startSession()
        var reply = ""
        defer { print("[proactive smoke] respuesta:", reply.prefix(240)) }
        for await event in await loop.run(sessionId: sid, userText: text) {
            switch event {
            case .textDelta(let t): reply += t
            case .error(let message): print("[proactive smoke] error:", message.prefix(300))
            case .toolStarted(let name): print("[proactive smoke] tool:", name)
            default: break
            }
        }
        return confirmation.requests.value
    }

    @Test func routesPersonalRemindersAndAgenda() async throws {
        guard ProcessInfo.processInfo.environment["ANIMA_PROACTIVE_SMOKE"] == "1" else { return }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".anima/test-token")
        let token = (try String(contentsOf: path, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let mode = AuthMode.detect(fromToken: token) else { return }

        let reminder = try await turn("recuérdame mañana a las 9 llamar al banco", token: token, mode: mode)
        let create = try #require(reminder.first { $0.tool == "anima_reminders" && $0.operation == "create" })
        let fireAt = try #require(create.input["fire_at"]?.stringValue.flatMap(AnimaRemindersTool.parseDate))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let expected = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
        print("[proactive smoke] recordatorio →", create.tool, create.summary)
        #expect(fireAt == expected)
        #expect(!reminder.contains { $0.tool == "calendar" || $0.tool == "reminders" })

        let agenda = try await turn("agéndame reunión con Pedro el jueves a las 3pm", token: token, mode: mode)
        print("[proactive smoke] agenda →", agenda.map { "\($0.tool).\($0.operation)" })
        #expect(agenda.contains { $0.tool == "calendar" && $0.operation == "create" })
        #expect(!agenda.contains { $0.tool == "anima_reminders" })
    }
}
