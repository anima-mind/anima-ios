import Foundation
import Testing
@testable import AnimaKit

@Suite struct AgentLoopTests {

    private func makeLoop(provider: Provider, notesRoot: URL) throws -> (AgentLoop, SymbolicStore, SessionID) {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let telemetry = Telemetry(queue: queue)
        let router = ModelRouter(config: try TestConfig.providerConfig())
        let loop = AgentLoop(
            provider: provider,
            store: store,
            telemetry: telemetry,
            router: router,
            authMode: .apiKey,
            token: "sk-ant-api03-xyz",
            clientTools: [NotesTool(root: notesRoot)],
            serverTools: [WebSearchTool.spec],
            sleep: { _ in })  // sin esperas reales
        let sid = try store.startSession()
        return (loop, store, sid)
    }

    /// Round 1: el modelo pide crear una nota. Round 2: responde texto y termina.
    @Test func toolLoopExecutesClientToolAndPersistsTranscript() async throws {
        let notesRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: notesRoot) }

        let round1: [ProviderEvent] = [
            .messageStart(id: "m1", model: "claude-opus-4-8"),
            .toolUseStart(id: "toolu_1", name: "notes"),
            .toolUseInputDelta(#"{"action":"create","name":"idea","content":"probar Anima"}"#),
            .blockStop(index: 0),
            .messageDelta(stopReason: .toolUse, usage: Usage(inputTokens: 50, outputTokens: 20)),
            .messageStop,
        ]
        let round2: [ProviderEvent] = [
            .messageStart(id: "m2", model: "claude-opus-4-8"),
            .textDelta("Listo, guardé la nota."),
            .blockStop(index: 0),
            .messageDelta(stopReason: .endTurn, usage: Usage(inputTokens: 80, outputTokens: 10)),
            .messageStop,
        ]
        let provider = ScriptedProvider([round1, round2])
        let (loop, store, sid) = try makeLoop(provider: provider, notesRoot: notesRoot)

        var events: [LoopEvent] = []
        for await event in await loop.run(sessionId: sid, userText: "guarda una idea") {
            events.append(event)
        }

        // La tool se ejecutó y el turno terminó con end_turn.
        #expect(events.contains(.toolStarted(name: "notes")))
        #expect(events.contains(.toolFinished(name: "notes", isError: false)))
        #expect(events.contains(.turnFinished(stopReason: .endTurn)))

        // El texto final se streameó.
        let streamed = events.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }.joined()
        #expect(streamed == "Listo, guardé la nota.")

        // La nota existe en el sandbox.
        let note = try String(contentsOf: notesRoot.appendingPathComponent("idea.txt"), encoding: .utf8)
        #expect(note == "probar Anima")

        // Transcript: user, assistant(tool_use), user(tool_result), assistant(text).
        let window = try store.window(sessionId: sid)
        #expect(window.count == 4)
        #expect(window[0].role == .user)
        #expect(window[1].role == .assistant)
        #expect(window[2].role == .user)   // tool_result va en un mensaje user
        if case .toolResult = window[2].content.first {} else { Issue.record("esperaba tool_result") }
        #expect(window[3].role == .assistant)
    }

    @Test func refusalIsShownWithoutCrashAndNotRetried() async throws {
        let notesRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: notesRoot) }

        let refusal: [ProviderEvent] = [
            .messageStart(id: "m1", model: "claude-opus-4-8"),
            .messageDelta(stopReason: .refusal, usage: Usage(inputTokens: 30, outputTokens: 0)),
            .messageStop,
        ]
        let provider = ScriptedProvider([refusal])
        let (loop, _, sid) = try makeLoop(provider: provider, notesRoot: notesRoot)

        var events: [LoopEvent] = []
        for await event in await loop.run(sessionId: sid, userText: "algo prohibido") {
            events.append(event)
        }
        #expect(events.contains(.refused))
        #expect(!events.contains { if case .turnFinished = $0 { return true } else { return false } })
    }

    /// La misma tool+input repetida dispara loop detection y detiene el turno.
    @Test func loopDetectionStopsTurn() async throws {
        let notesRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: notesRoot) }

        let round: [ProviderEvent] = [
            .messageStart(id: "m", model: "claude-opus-4-8"),
            .toolUseStart(id: "toolu", name: "notes"),
            .toolUseInputDelta(#"{"action":"list"}"#),
            .blockStop(index: 0),
            .messageDelta(stopReason: .toolUse, usage: Usage(inputTokens: 10, outputTokens: 5)),
            .messageStop,
        ]
        // Tres rondas idénticas → la 3ª repetición detiene.
        let provider = ScriptedProvider([round, round, round, round])
        let (loop, _, sid) = try makeLoop(provider: provider, notesRoot: notesRoot)

        var events: [LoopEvent] = []
        for await event in await loop.run(sessionId: sid, userText: "lista mis notas") {
            events.append(event)
        }
        #expect(events.contains(.stopped(.loopDetected)))
    }

    /// Turno multimodal: un image block en el content del turno fluye sin crash.
    @Test func multimodalImageTurn() async throws {
        let notesRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: notesRoot) }

        let round: [ProviderEvent] = [
            .messageStart(id: "m", model: "claude-opus-4-8"),
            .textDelta("Veo una foto azul."),
            .blockStop(index: 0),
            .messageDelta(stopReason: .endTurn, usage: Usage(inputTokens: 100, outputTokens: 8)),
            .messageStop,
        ]
        let provider = ScriptedProvider([round])
        let (loop, store, sid) = try makeLoop(provider: provider, notesRoot: notesRoot)

        let content: [ContentBlock] = [.text("¿qué ves?"), .image(mediaType: "image/jpeg", base64: "AQID")]
        var events: [LoopEvent] = []
        for await event in await loop.run(sessionId: sid, content: content) {
            events.append(event)
        }
        #expect(events.contains(.turnFinished(stopReason: .endTurn)))

        // El turno multimodal se persistió con texto + imagen.
        let window = try store.window(sessionId: sid)
        #expect(window.first?.content.contains(.image(mediaType: "image/jpeg", base64: "AQID")) == true)
    }

    @Test func pauseTurnResumesUntilEndTurn() async throws {
        let notesRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: notesRoot) }

        // Round 1: server tool (web_search) pausa el turno. Round 2: termina.
        let paused: [ProviderEvent] = [
            .messageStart(id: "m1", model: "claude-opus-4-8"),
            .textDelta("Buscando…"),
            .blockStop(index: 0),
            .messageDelta(stopReason: .pauseTurn, usage: Usage(inputTokens: 40, outputTokens: 5)),
            .messageStop,
        ]
        let done: [ProviderEvent] = [
            .messageStart(id: "m2", model: "claude-opus-4-8"),
            .textDelta("Aquí está el resultado."),
            .blockStop(index: 0),
            .messageDelta(stopReason: .endTurn, usage: Usage(inputTokens: 60, outputTokens: 15)),
            .messageStop,
        ]
        let provider = ScriptedProvider([paused, done])
        let (loop, store, sid) = try makeLoop(provider: provider, notesRoot: notesRoot)

        var events: [LoopEvent] = []
        for await event in await loop.run(sessionId: sid, userText: "busca algo") {
            events.append(event)
        }
        #expect(events.contains(.turnFinished(stopReason: .endTurn)))
        // Ambos mensajes de assistant se persistieron (pause_turn reenvía y continúa).
        let window = try store.window(sessionId: sid)
        let assistantCount = window.filter { $0.role == .assistant }.count
        #expect(assistantCount == 2)
    }
}
