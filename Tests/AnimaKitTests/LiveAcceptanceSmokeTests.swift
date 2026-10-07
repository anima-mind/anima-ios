import Foundation
import Testing
@testable import AnimaKit

/// Smoke opt-in (ANIMA_ACCEPT_SMOKE=1, token en ~/.anima/test-token, jamás
/// impreso): "Hagámoslo" a una propuesta de check-in con Claude real ⇒ la tool
/// se EJECUTA (check-in de la meta o recordatorio ligado), no solo se promete.
@Suite struct LiveAcceptanceSmokeTests {
    @Test func claudeEjecutaLaPropuestaAceptada() async throws {
        guard ProcessInfo.processInfo.environment["ANIMA_ACCEPT_SMOKE"] == "1" else { return }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".anima/test-token")
        let token = (try String(contentsOf: path, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let mode = AuthMode.detect(fromToken: token) else { return }
        let api = ProviderAPIConfig(
            baseURL: URL(string: "https://api.anthropic.com")!, version: "2023-06-01", betas: [],
            authBetas: [.oauth: ["oauth-2025-04-20", "claude-code-20250219"]],
            authSystemPrefixes: [.oauth: "You are Claude Code, Anthropic's official CLI for Claude."])
        let config = ProviderConfig(
            systemPromptBase: "Eres Anima, la asistente personal del dueño. Hablas en español, cálida y directa.",
            api: api,
            routes: [.interactive: ModelRoute(model: "claude-opus-4-8", effort: "medium", maxTokens: 4000)])
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let other = OtherModel(queue: queue)
        let reminders = AnimaReminderStore(queue: queue)
        let goalId = await other.ingestStated(statement: "Bajar 10 kg", desiredState: .progressCheckIn(everyDays: 7),
                                              evidence: "smoke")
        let loop = AgentLoop(provider: ClaudeProvider(), store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: config), authMode: mode, token: token,
                             clientTools: [GoalsTool(otherModel: other), AnimaRemindersTool(store: reminders)],
                             serverTools: [], permissionPolicy: .app(ownerAllowlist: { [] }), sleep: { _ in })
        let sid = try store.startSession()
        let prompt = IntentionAcceptance.prompt(
            proposal: "¿El miércoles a las 8:00 hacemos tu primer check-in de la meta de bajar 10 kg?", goalId: goalId)
        var tools: [String] = []; var retracted = false; var text = ""
        for await event in await loop.run(sessionId: sid, userText: prompt) {
            switch event {
            case .toolFinished(let name, false): tools.append(name)
            case .retracted: retracted = true; text = ""
            case .textDelta(let t): text += t
            default: break
            }
        }
        let goal = await other.goal(id: goalId)
        let linked = await reminders.list().filter { $0.goalId == goalId }
        print("[accept smoke] tools:", tools, "retracted:", retracted, "checkin:", goal?.checkIn.phrase ?? "-",
              "recordatorios ligados:", linked.count)
        print("[accept smoke] texto:", text)
        #expect(goal?.checkIn.isActive == true || !linked.isEmpty)
        #expect(!text.hasPrefix(ActionClaimGuard.marker))
    }
}
