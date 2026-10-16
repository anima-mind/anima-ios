import Foundation
import GRDB
import Testing
@testable import AnimaKit

/// Smoke opt-in (ANIMA_GOALS_SMOKE=1, token en ~/.anima/test-token, jamás
/// impreso) del bug de campo 2026-10-15 con Claude real: "ya no quiero ahorrar,
/// mejor quiero abonar a la deuda" en el chat ⇒ la meta vieja queda reemplazada;
/// y el sueño con el modelo real (Haiku) no la resucita ni deja las dos.
@Suite(.serialized) struct LiveGoalReplacementSmokeTests {
    static let oldStatement = "Ahorrar 30 millones de pesos para diciembre de 2026"
    static let day1 = "Quiero ahorrar 30 millones de pesos para diciembre de 2026, pregúntame cada miércoles a las 6:33 pm"
    static let dayN = "ya no quiero ahorrar, mejor quiero abonar a la deuda 5M cada quincena"

    static func credentials() throws -> (String, AuthMode)? {
        guard ProcessInfo.processInfo.environment["ANIMA_GOALS_SMOKE"] == "1" else { return nil }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".anima/test-token")
        let token = (try String(contentsOf: path, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let mode = AuthMode.detect(fromToken: token) else { return nil }
        return (token, mode)
    }

    static func config() -> ProviderConfig {
        let api = ProviderAPIConfig(
            baseURL: URL(string: "https://api.anthropic.com")!, version: "2023-06-01", betas: [],
            authBetas: [.oauth: ["oauth-2025-04-20", "claude-code-20250219"]],
            authSystemPrefixes: [.oauth: "You are Claude Code, Anthropic's official CLI for Claude."])
        let haiku = ModelRoute(model: "claude-haiku-4-5", effort: nil, maxTokens: 2000)
        return ProviderConfig(
            systemPromptBase: "Eres Anima, la asistente personal del dueño. Hablas en español, cálida y directa.",
            api: api,
            routes: [.interactive: ModelRoute(model: "claude-opus-4-8", effort: "medium", maxTokens: 4000),
                     .distill: haiku, .consolidation: haiku, .reconsolidation: haiku])
    }

    struct World {
        let queue: DatabaseQueue
        /// nil = reloj real; la meta del día 1 se declara hace 10 días (como en campo).
        let clock: Locked<Date?>
        let other: OtherModel
        let reminders: AnimaReminderStore
        let store: SymbolicStore
        init() throws {
            queue = try AnimaDatabase.temporary()
            let clock = Locked<Date?>(nil)
            self.clock = clock
            other = OtherModel(queue: queue, now: { clock.value ?? Date() })
            reminders = AnimaReminderStore(queue: queue)
            store = SymbolicStore(queue: queue)
        }
        func at(daysAgo: Double?) { clock.mutate { $0 = daysAgo.map { Date().addingTimeInterval(-$0 * 86_400) } } }
        func owner(_ text: String, daysAgo: Double) throws {
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO consolidation_inbox (session_id, text, source, created_at, cycle, consolidated_at)
                    VALUES ('s1', ?, 'turn', ?, NULL, NULL)
                    """, arguments: [text, Date().addingTimeInterval(-daysAgo * 86_400).timeIntervalSince1970])
            }
        }
        func seedSaving() async -> String {
            at(daysAgo: 10)
            defer { at(daysAgo: nil) }
            let id = await other.ingestStated(statement: LiveGoalReplacementSmokeTests.oldStatement,
                                              desiredState: .progressCheckIn(everyDays: 8), evidence: "smoke")
            await other.setCheckIn(id: id, CheckInCadence(cadence: .weekly, hour: 18, minute: 33, weekday: 4))
            return id
        }
        func sleep(token: String, mode: AuthMode) async throws -> Consolidator.CycleReport {
            let consolidator = Consolidator(brain: Brain(queue: queue, embedder: Embedder(forceFallback: true)),
                                            queue: queue, provider: ClaudeProvider(),
                                            router: ModelRouter(config: LiveGoalReplacementSmokeTests.config()),
                                            authMode: mode, token: token, otherModel: other)
            return try await consolidator.cycle()
        }
        func open() async -> [Goal] { await other.allGoals().filter(\.isOpen) }
    }

    @Test func claudeReplacesTheGoalInChatAndTheSleepKeepsIt() async throws {
        guard let (token, mode) = try Self.credentials() else { return }
        let w = try World()
        let old = await w.seedSaving()
        try w.owner(Self.day1, daysAgo: 10)
        let loop = AgentLoop(provider: ClaudeProvider(), store: w.store, telemetry: Telemetry(queue: w.queue),
                             router: ModelRouter(config: Self.config()), authMode: mode, token: token,
                             clientTools: [GoalsTool(otherModel: w.other), AnimaRemindersTool(store: w.reminders)],
                             serverTools: [], permissionPolicy: .app(ownerAllowlist: { [] }), sleep: { _ in })
        let sid = try w.store.startSession()
        try w.owner(Self.dayN, daysAgo: 0.01)
        var tools: [String] = []; var text = ""
        for await event in await loop.run(sessionId: sid, userText: Self.dayN) {
            switch event {
            case .toolFinished(let name, false): tools.append(name)
            case .retracted: text = ""
            case .textDelta(let t): text += t
            default: break
            }
        }
        let afterChat = await w.open()
        print("[goals smoke] chat tools:", tools, "abiertas:", afterChat.map(\.statement))
        print("[goals smoke] texto:", text)
        #expect(afterChat.count == 1 && afterChat.first?.statement.lowercased().contains("deuda") == true)
        #expect(await w.other.goal(id: old)?.status == .abandoned)
        #expect(!text.hasPrefix(ToolFailureNotice.marker) && !text.hasPrefix(ActionClaimGuard.marker))

        let report = try await w.sleep(token: token, mode: mode)
        let afterSleep = await w.open()
        print("[goals smoke] sueño:", report.completed, "abiertas:", afterSleep.map(\.statement))
        #expect(report.completed)
        #expect(afterSleep.count == 1 && afterSleep.first?.statement.lowercased().contains("deuda") == true)
        #expect(await w.other.goal(id: old)?.status == .abandoned)
    }

    @Test func theRealSleepFixesWhatTheChatMissed() async throws {
        guard let (token, mode) = try Self.credentials() else { return }
        let w = try World()
        let old = await w.seedSaving()
        try w.owner(Self.day1, daysAgo: 10)
        try w.owner(Self.dayN, daysAgo: 2)
        w.at(daysAgo: 2)
        _ = await w.other.ingestStated(statement: "Abonar 5M a la deuda cada quincena",
                                       desiredState: .progressCheckIn(everyDays: 15), evidence: "smoke")
        w.at(daysAgo: nil)
        let report = try await w.sleep(token: token, mode: mode)
        let open = await w.open()
        print("[goals smoke] sueño (chat sin replace):", report.completed, "abiertas:", open.map(\.statement),
              "dejadas:", report.goalsLeft)
        #expect(open.count == 1 && open.first?.statement.lowercased().contains("deuda") == true)
        #expect(await w.other.goal(id: old)?.status == .abandoned)
    }
}
