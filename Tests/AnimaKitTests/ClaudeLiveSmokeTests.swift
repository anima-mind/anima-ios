import Foundation
import Testing
@testable import AnimaKit

/// Smoke real contra api.anthropic.com en modo OAuth — opt-in (ANIMA_CLAUDE_SMOKE=1)
/// y con el token en ~/.anima/test-token. El token jamás se imprime.
@Suite struct ClaudeLiveSmokeTests {
    @Test func claudeLiveSmoke() async throws {
        guard ProcessInfo.processInfo.environment["ANIMA_CLAUDE_SMOKE"] == "1" else { return }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".anima/test-token")
        let token = (try String(contentsOf: path, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { print("[claude smoke] sin token, skip"); return }

        let mode = AuthMode.detect(fromToken: token)
        print("[claude smoke] auth mode detectado:", mode.map(String.init(describing:)) ?? "nil")
        guard let mode else { return }

        let api = ProviderAPIConfig(
            baseURL: URL(string: "https://api.anthropic.com")!,
            version: "2023-06-01",
            betas: [],
            authBetas: [.oauth: ["oauth-2025-04-20", "claude-code-20250219"]],
            authSystemPrefixes: [.oauth: "You are Claude Code, Anthropic's official CLI for Claude."])
        let opts = CallOpts(
            route: ModelRoute(model: "claude-opus-4-8", effort: "medium", maxTokens: 1000),
            api: api, authMode: mode, token: token,
            systemPromptBase: "Eres Anima, una mente personal. Responde breve, en español.")

        let provider = ClaudeProvider()
        let res = try await provider.completeCollecting(
            AssembledContext(messages: [.user("Di hola en una frase corta y di qué modelo eres.")]),
            tools: [], opts: opts)
        print("[claude smoke] stop:", res.stopReason as Any)
        print("[claude smoke] texto:", res.content)
        print("[claude smoke] usage in/out:", res.usage.inputTokens, res.usage.outputTokens)
        #expect(res.stopReason == .endTurn)
    }
}
