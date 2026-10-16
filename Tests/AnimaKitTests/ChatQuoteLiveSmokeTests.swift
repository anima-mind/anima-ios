import Foundation
import GRDB
import Testing
@testable import AnimaKit

/// "Responder citando" contra modelos REALES — opt-in (ANIMA_QUOTE_SMOKE=1).
/// El dueño cita un recordatorio y dice "pásalo para el viernes N a la misma
/// hora": el modelo debe mover ESE recordatorio (el id citado) y no tocar otro.
/// Claude: token en ~/.anima/test-token (jamás se imprime). Modelo de Apple:
/// si está disponible (Apple Intelligence encendido), con las tools de la cita.
@Suite(.serialized) struct ChatQuoteLiveSmokeTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["ANIMA_QUOTE_SMOKE"] == "1" }

    struct Case {
        let quoted: AnimaReminder
        let other: AnimaReminder
        let target: Date
        let prompt: String
        let store: AnimaReminderStore
        let symbolic: SymbolicStore
        let queue: DatabaseQueue
    }

    /// Martes próximo 6:33 p. m. (citado) y miércoles (control); objetivo: el viernes de esa semana.
    static func makeCase() async throws -> Case {
        let queue = try AnimaDatabase.temporary()
        let store = AnimaReminderStore(queue: queue)
        let cal = Calendar.current
        var tuesday = cal.nextDate(after: Date(), matching: DateComponents(hour: 18, minute: 33, weekday: 3),
                                   matchingPolicy: .nextTime)!
        if tuesday.timeIntervalSinceNow < 2 * 86_400 { tuesday = cal.date(byAdding: .day, value: 7, to: tuesday)! }
        let quoted = try await store.create(text: "abonar 5M a la deuda", message: "Oye, hoy toca abonar los 5M.",
                                            fireAt: tuesday)
        let other = try await store.create(text: "llamar al banco", message: "Oye, llama al banco.",
                                           fireAt: cal.date(byAdding: .day, value: 1, to: tuesday)!)
        let target = cal.date(byAdding: .day, value: 3, to: tuesday)!
        let day = cal.component(.day, from: target)
        return Case(quoted: quoted, other: other, target: target,
                    prompt: "pásalo para el viernes \(day) a la misma hora", store: store,
                    symbolic: SymbolicStore(queue: queue), queue: queue)
    }

    static func run(_ c: Case, loop: AgentLoop, compact: Bool) async throws -> (calls: [String], text: String) {
        let sid = try c.symbolic.startSession()
        let quote = ChatQuoteResolver.quote(c.quoted)
        var calls: [String] = []
        var text = ""
        for await event in await loop.run(sessionId: sid, content: [.text(c.prompt)], surface: .phoneChat,
                                          quote: quote) {
            switch event {
            case .assistantMessage(let blocks):
                for case .toolUse(_, let name, let input) in blocks { calls.append("\(name) \(LoopDetector.canonical(input))") }
            case .textDelta(let t): text += t
            case .error(let m): print("[quote smoke] error:", m.prefix(200))
            default: break
            }
        }
        print("[quote smoke] \(compact ? "local" : "claude") prompt=\(c.prompt) calls=\(calls) texto=\(text.prefix(200))")
        return (calls, text)
    }

    static func assertMoved(_ c: Case) async {
        let moved = await c.store.reminder(id: c.quoted.id)
        let untouched = await c.store.reminder(id: c.other.id)
        #expect(moved?.fireAt == c.target, "citado: \(String(describing: moved?.fireAt)) ≠ \(c.target)")
        #expect(moved?.status == .scheduled)
        #expect(untouched?.fireAt == c.other.fireAt && untouched?.status == .scheduled, "el otro no se toca")
    }

    @Test func claudeMovesTheQuotedReminder() async throws {
        guard Self.enabled else { return }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".anima/test-token")
        guard let token = try? String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty, let mode = AuthMode.detect(fromToken: token) else {
            print("[quote smoke] sin token de Claude, skip"); return
        }
        let c = try await Self.makeCase()
        let api = ProviderAPIConfig(
            baseURL: URL(string: "https://api.anthropic.com")!, version: "2023-06-01", betas: [],
            authBetas: [.oauth: ["oauth-2025-04-20", "claude-code-20250219"]],
            authSystemPrefixes: [.oauth: "You are Claude Code, Anthropic's official CLI for Claude."])
        let config = ProviderConfig(
            systemPromptBase: "Eres Anima, una mente personal que vive en el teléfono del dueño. Responde breve, en español. Usa tus herramientas cuando el dueño te pida algo que ellas resuelven.",
            api: api, routes: [.interactive: ModelRoute(model: "claude-opus-4-8", effort: "medium", maxTokens: 2000)])
        let loop = AgentLoop(provider: ClaudeProvider(), store: c.symbolic, telemetry: Telemetry(queue: c.queue),
                             router: ModelRouter(config: config), authMode: mode, token: token,
                             clientTools: [AnimaRemindersTool(store: c.store)], serverTools: [],
                             permissionPolicy: .app(ownerAllowlist: { [] }), sleep: { _ in })
        let r = try await Self.run(c, loop: loop, compact: false)
        #expect(r.calls.contains { $0.contains(c.quoted.id) }, "actuó sobre el id citado")
        #expect(!r.calls.contains { $0.contains(c.other.id) })
        await Self.assertMoved(c)
    }

    @Test func theLocalModelMovesTheQuotedReminder() async throws {
        guard Self.enabled else { return }
        guard OnDeviceAvailability.current().isAvailable else {
            print("[quote smoke] modelo de Apple no disponible (\(OnDeviceAvailability.current().rawValue)), skip"); return
        }
        let c = try await Self.makeCase()
        let loop = AgentLoop(provider: OnDeviceProvider.system(), store: c.symbolic,
                             telemetry: Telemetry(queue: c.queue), router: try OnDeviceTestConfig.router(),
                             authMode: .apiKey, token: "", clientTools: [AnimaRemindersTool(store: c.store)],
                             serverTools: [], permissionPolicy: .app(ownerAllowlist: { [] }), sleep: { _ in })
        let r = try await Self.run(c, loop: loop, compact: true)
        #expect(r.calls.contains { $0.hasPrefix("move_reminder") }, "usó la tool de la cita")
        await Self.assertMoved(c)
    }
}
