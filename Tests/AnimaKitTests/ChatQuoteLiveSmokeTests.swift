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

    static func run(_ c: Case, loop: AgentLoop, compact: Bool, prompt: String? = nil) async throws
        -> (calls: [String], text: String) {
        let sid = try c.symbolic.startSession()
        let quote = ChatQuoteResolver.quote(c.quoted)
        var calls: [String] = []
        var text = ""
        for await event in await loop.run(sessionId: sid, content: [.text(prompt ?? c.prompt)], surface: .phoneChat,
                                          quote: quote) {
            switch event {
            case .assistantMessage(let blocks):
                for case .toolUse(_, let name, let input) in blocks { calls.append("\(name) \(LoopDetector.canonical(input))") }
            case .textDelta(let t): text += t
            case .retracted: text = ""
            case .error(let m): print("[quote smoke] error:", m.prefix(200))
            default: break
            }
        }
        print("[quote smoke] \(compact ? "local" : "claude") prompt=\(prompt ?? c.prompt) calls=\(calls) texto=\(text.prefix(200))")
        return (calls, text)
    }

    static func assertMoved(_ c: Case) async {
        let moved = await c.store.reminder(id: c.quoted.id)
        let untouched = await c.store.reminder(id: c.other.id)
        #expect(moved?.fireAt == c.target, "citado: \(String(describing: moved?.fireAt)) ≠ \(c.target)")
        #expect(moved?.status == .scheduled)
        #expect(untouched?.fireAt == c.other.fireAt && untouched?.status == .scheduled, "el otro no se toca")
    }

    /// Review #43 (MEDIO 2): sin pedido del dueño no se toca nada.
    static let controls = ["gracias", "¿a qué hora era?"]

    static func assertUntouched(_ c: Case, _ calls: [String], _ prompt: String) async {
        for r in [c.quoted, c.other] {
            let now = await c.store.reminder(id: r.id)
            #expect(now?.fireAt == r.fireAt && now?.status == .scheduled, "\(prompt): \(r.text) cambió")
        }
        #expect(!calls.contains { $0.contains("reschedule") || $0.contains("complete") || $0.contains("cancel")
            || $0.hasPrefix("move_reminder") || $0.hasPrefix("done_reminder") }, "\(prompt): \(calls)")
    }

    static func claudeLoop(_ c: Case) -> AgentLoop? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".anima/test-token")
        guard let token = try? String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty, let mode = AuthMode.detect(fromToken: token) else { return nil }
        let api = ProviderAPIConfig(
            baseURL: URL(string: "https://api.anthropic.com")!, version: "2023-06-01", betas: [],
            authBetas: [.oauth: ["oauth-2025-04-20", "claude-code-20250219"]],
            authSystemPrefixes: [.oauth: "You are Claude Code, Anthropic's official CLI for Claude."])
        let config = ProviderConfig(
            systemPromptBase: "Eres Anima, una mente personal que vive en el teléfono del dueño. Responde breve, en español. Usa tus herramientas cuando el dueño te pida algo que ellas resuelven.",
            api: api, routes: [.interactive: ModelRoute(model: "claude-opus-4-8", effort: "medium", maxTokens: 2000)])
        return AgentLoop(provider: ClaudeProvider(), store: c.symbolic, telemetry: Telemetry(queue: c.queue),
                         router: ModelRouter(config: config), authMode: mode, token: token,
                         clientTools: [AnimaRemindersTool(store: c.store)], serverTools: [],
                         permissionPolicy: .app(ownerAllowlist: { [] }), sleep: { _ in })
    }

    static func localLoop(_ c: Case) throws -> AgentLoop {
        AgentLoop(provider: OnDeviceProvider.system(), store: c.symbolic, telemetry: Telemetry(queue: c.queue),
                  router: try OnDeviceTestConfig.router(), authMode: .apiKey, token: "",
                  clientTools: [AnimaRemindersTool(store: c.store)], serverTools: [],
                  permissionPolicy: .app(ownerAllowlist: { [] }), sleep: { _ in })
    }

    @Test func noRequestNoChange() async throws {
        guard Self.enabled else { return }
        for prompt in Self.controls {
            let c = try await Self.makeCase()
            if let claude = Self.claudeLoop(c) {
                let r = try await Self.run(c, loop: claude, compact: false, prompt: prompt)
                await Self.assertUntouched(c, r.calls, prompt)
            }
            if OnDeviceAvailability.current().isAvailable {
                let d = try await Self.makeCase()
                let r = try await Self.run(d, loop: try Self.localLoop(d), compact: true, prompt: prompt)
                await Self.assertUntouched(d, r.calls, prompt)
            }
        }
    }

    /// Review #43 ronda 2: la tabla de frases que NUNCA deben marcar hecho ni
    /// mover (3 intentos con el modelo de Apple, 1 con Claude) y las que sí
    /// marcan hecho. Imprime una fila por corrida: `[quote-table] …`.
    static var attempts: Int { Int(ProcessInfo.processInfo.environment["ANIMA_QUOTE_RUNS"] ?? "") ?? 3 }

    @Test func phraseTable() async throws {
        guard Self.enabled else { return }
        let local = OnDeviceAvailability.current().isAvailable
        var touched: [String] = []
        for phrase in QuotedLocalToolsTests.neverAct {
            for model in ["apple", "claude"] {
                let runs = model == "apple" ? (local ? Self.attempts : 0) : 1
                for run in 0..<runs {
                    let c = try await Self.makeCase()
                    guard let loop = model == "apple" ? try Self.localLoop(c) : Self.claudeLoop(c) else { continue }
                    let r = try await Self.run(c, loop: loop, compact: model == "apple", prompt: phrase)
                    let now = await c.store.reminder(id: c.quoted.id)
                    // Tampoco se crea otro (medido: el 3B duplicaba el citado).
                    let created = await c.store.list(.all).count - 2
                    #expect(created == 0, "\(model) \(phrase) #\(run + 1): creó \(created)")
                    if created > 0 { touched.append("\(model): \(phrase) (creó otro)") }
                    // "ya no me lo recuerdes" pide cancelarlo: con Claude eso es correcto.
                    let cancelAsked = model == "claude" && phrase == "ya no me lo recuerdes" && now?.status == .cancelled
                    let changed = !cancelAsked && (now?.status != .scheduled || now?.fireAt != c.quoted.fireAt)
                    let outcome = cancelAsked ? "cancelado (pedido)" : changed ? "CAMBIÓ: \(now?.status.rawValue ?? "?")" : "intacto"
                    print("[quote-table] \(model) | \(phrase) | \(run + 1) | \(outcome) | \(r.calls)")
                    if changed { touched.append("\(model): \(phrase)") }
                    #expect(!changed, "\(model) \(phrase) #\(run + 1)")
                }
            }
        }
        print("[quote-table] negativas que tocaron algo: \(touched.count) \(touched)")
        for phrase in ["ya lo pagué", "listo", "ya lo hice"] {
            for model in ["apple", "claude"] {
                let runs = model == "apple" ? (local ? Self.attempts : 0) : 1
                for run in 0..<runs {
                    let c = try await Self.makeCase()
                    guard let loop = model == "apple" ? try Self.localLoop(c) : Self.claudeLoop(c) else { continue }
                    let r = try await Self.run(c, loop: loop, compact: model == "apple", prompt: phrase)
                    let now = await c.store.reminder(id: c.quoted.id)
                    print("[quote-table] \(model) | \(phrase) | \(run + 1) | \(now?.status == .done ? "HECHO" : "no marcado") | \(r.calls)")
                    // Claude puede preguntar ante un "listo" suelto (falso negativo aceptable).
                    if !(model == "claude" && phrase == "listo") {
                        #expect(now?.status == .done, "\(model) \(phrase) #\(run + 1)")
                    }
                    let other = await c.store.reminder(id: c.other.id)
                    #expect(other?.status == .scheduled)
                }
            }
        }
    }

    /// Deshacer por chat con el modelo de Apple: "no lo he hecho" sobre uno recién hecho.
    @Test func theLocalModelUndoesARecentDone() async throws {
        guard Self.enabled, OnDeviceAvailability.current().isAvailable else { return }
        for run in 0..<Self.attempts {
            let c = try await Self.makeCase()
            _ = try await c.store.complete(id: c.quoted.id)
            let done = await c.store.reminder(id: c.quoted.id)
            let quote = ChatQuoteResolver.quote(try #require(done))
            let sid = try c.symbolic.startSession()
            var calls: [String] = []
            let undoLoop = try Self.localLoop(c)
            for await event in await undoLoop.run(sessionId: sid, content: [.text("no lo he hecho")],
                                                         surface: .phoneChat, quote: quote) {
                if case .assistantMessage(let blocks) = event {
                    for case .toolUse(_, let name, _) in blocks { calls.append(name) }
                }
            }
            let now = await c.store.reminder(id: c.quoted.id)
            print("[quote-table] apple | no lo he hecho (sobre uno hecho) | \(run + 1) | \(now?.status == .scheduled ? "REACTIVADO" : "sigue hecho") | \(calls)")
            #expect(now?.status == .scheduled)
        }
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
