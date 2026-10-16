import Foundation
import GRDB
import Testing
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif
@testable import AnimaKit

/// El sueño REAL dejando las preguntas de los avisos por inactividad — opt-in:
/// `ANIMA_NUDGE_SMOKE=claude` (token en ~/.anima/test-token, jamás se imprime;
/// Haiku) o `ANIMA_NUDGE_SMOKE=local` (modelo de Apple, Apple Intelligence
/// encendido). Un ciclo completo con mensajes del dueño, una meta y una memoria;
/// las preguntas deben salir 3–5, en español, cortas, sin nada sensible y al
/// menos una anclada en lo que contó. Una fila por pregunta: `[nudge-smoke] …`.
@Suite(.serialized) struct LiveReengagementSmokeTests {
    static var mode: String? { ProcessInfo.processInfo.environment["ANIMA_NUDGE_SMOKE"] }

    static func claudeSelector() throws -> ProviderSelector? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".anima/test-token")
        let token = (try String(contentsOf: path, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let auth = AuthMode.detect(fromToken: token) else { return nil }
        let api = ProviderAPIConfig(
            baseURL: URL(string: "https://api.anthropic.com")!, version: "2023-06-01", betas: [],
            authBetas: [.oauth: ["oauth-2025-04-20", "claude-code-20250219"]],
            authSystemPrefixes: [.oauth: "You are Claude Code, Anthropic's official CLI for Claude."])
        let haiku = ModelRoute(model: "claude-haiku-4-5", effort: nil, maxTokens: 2000)
        var routes: [TurnClass: ModelRoute] = [:]
        for turn in TurnClass.allCases { routes[turn] = haiku }
        let router = ModelRouter(config: ProviderConfig(systemPromptBase: "", api: api, routes: routes))
        return .claudeOnly(provider: ClaudeProvider(), router: router, authMode: auth, token: token)
    }

    static func localSelector() throws -> ProviderSelector? {
        guard OnDeviceAvailability.current().isAvailable else {
            print("[nudge-smoke] modelo local no disponible: \(OnDeviceAvailability.current().rawValue)")
            return nil
        }
        return ProviderSelector(mode: .onDeviceOnly, remote: nil,
                                local: .init(provider: OnDeviceProvider.system(), router: try OnDeviceTestConfig.router()),
                                availability: { .available })
    }

    @Test func elSuenoRealDejaPreguntasPersonales() async throws {
        guard let mode = Self.mode, ["claude", "local"].contains(mode) else { return }
        guard let selector = try (mode == "claude" ? Self.claudeSelector() : Self.localSelector()) else { return }
        let queue = try AnimaDatabase.temporary()
        let brain = Brain(queue: queue, embedder: Embedder(forceFallback: true))
        let inbox = ConsolidationInbox(queue: queue)
        let other = OtherModel(queue: queue)
        let selfModel = SelfModel(queue: queue, birth: Birth(name: "Lumen", tone: "cercano, cálido y directo",
                                                             language: "español (es-CO)"))
        let questions = ReengagementQuestionStore(queue: queue)
        _ = try await brain.add(MemoryCandidate(content: "El dueño tiene una reunión con Pedro el jueves por el proyecto nuevo",
                                                kind: .episodic, importance: 8), cycle: 0)
        _ = await other.ingestStated(statement: "Ir al gym 3 veces por semana",
                                     desiredState: .workoutsPerWeek(atLeast: 3), evidence: "quiero volver al gym")
        for text in ["Mañana me reúno con Pedro por lo del proyecto nuevo, ando algo nervioso.",
                     "Esta semana quiero volver al gym, la anterior no fui ni una vez.",
                     "Mi hermana Ana llega de visita el sábado."] {
            try inbox.enqueue(sessionId: "s1", text: text)
        }
        let consolidator = Consolidator(brain: brain, queue: queue, selector: selector, selfModel: selfModel,
                                        otherModel: other, nudgeQuestions: questions)
        let started = Date()
        let report = try await consolidator.cycle()
        let saved = questions.upcoming(limit: 10).map(\.text)
        print("[nudge-smoke] \(mode) ciclo completo=\(report.completed) en \(Int(Date().timeIntervalSince(started))) s")
        for q in saved { print("[nudge-smoke] \(mode) | \(q)") }
        #expect(report.completed)
        #expect((3...5).contains(saved.count), "salieron \(saved.count)")
        #expect(saved.allSatisfy(ReengagementTextGuard.isAllowed))
        let anchors = ["pedro", "reunión", "reunion", "proyecto", "gym", "ana", "hermana", "visita", "entren"]
        #expect(saved.contains { q in anchors.contains { q.lowercased().contains($0) } }, "ninguna anclada")
        #if canImport(NaturalLanguage)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(saved.joined(separator: " "))
        #expect(recognizer.dominantLanguage == .spanish)
        #endif
    }
}
