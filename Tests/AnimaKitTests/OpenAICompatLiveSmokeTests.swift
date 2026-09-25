import Foundation
import Testing
@testable import AnimaKit

/// Smokes de TURNO COMPLETO CON TOOLS contra OpenAI y Gemini reales — opt-in.
/// Círculo entero por el AgentLoop: user → tool_call → Sensorimotor ejecuta →
/// role:tool → el modelo responde con el dato. Usa la config BUNDLED
/// (App/RemoteConfigDefaults.plist): valida los model ids que shippea la app.
///
///   ANIMA_OPENAI_SMOKE=1  → key en ~/.anima/openai-key
///   ANIMA_GOOGLE_SMOKE=1  → key en ~/.anima/google-key
///
/// Archivo ausente o vacío → skip silencioso. Las keys JAMÁS se imprimen.
@Suite struct OpenAICompatLiveSmokeTests {

    /// Los errores de auth del API citan la key enmascarada: fuera del log.
    static func redact(_ s: String) -> String {
        s.replacingOccurrences(of: #"(sk-|AIza)[A-Za-z0-9_\-\*]+"#, with: "<redacted>", options: .regularExpression)
    }

    private func key(_ file: String) -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".anima/\(file)")
        let key = ((try? String(contentsOf: path, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private func bundledConfig(_ provider: ModelProvider) throws -> ProviderConfig {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/RemoteConfigDefaults.plist")
        let dict = try #require(NSDictionary(contentsOf: plist) as? [String: String])
        let parsed = try ProviderConfigParser.parse(Data(try #require(dict["provider_config"]).utf8))
        let entry = try #require(parsed[provider])
        let base = (dict[ProviderConfigParser.promptKey(for: provider)] ?? "")
            + " Usa la tool notes cuando el dueño pregunte por sus notas."
        return ProviderConfig(systemPromptBase: base, api: entry.api, routes: entry.routes)
    }

    private func runToolTurn(provider kind: ModelProvider, key: String, tag: String) async throws {
        let config = try bundledConfig(kind)
        let remote = try #require(RemoteCortexFactory.make(kind: kind, config: config, token: key))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = await NotesTool(root: root).execute(.object([
            "action": .string("create"), "name": .string("clave"),
            "content": .string("La palabra clave del dueño es mango-42.")]))
        try #require(!seeded.isError)

        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let selector = ProviderSelector(mode: .remote, remote: remote, local: nil,
                                        availability: { .deviceNotEligible })
        let loop = AgentLoop(selector: selector, store: store, telemetry: Telemetry(queue: queue),
                             clientTools: [NotesTool(root: root)], serverTools: [WebSearchTool.spec],
                             sleep: { _ in })
        let sid = try store.startSession()

        var tools: [String] = []
        var text = ""
        var stop: StopReason?
        var errors: [String] = []
        for await event in await loop.run(sessionId: sid,
                                          userText: "Lee la nota llamada 'clave' y dime cuál es la palabra clave, exacta.") {
            switch event {
            case .toolFinished(let name, let isError): if !isError { tools.append(name) }
            case .textDelta(let t): text += t
            case .turnFinished(let s): stop = s
            case .error(let e): errors.append(e)
            default: break
            }
        }
        print("[\(tag) tool-turn] modelo:", config.routes[.interactive]?.model ?? "?",
              "tools:", tools, "stop:", stop as Any, "errores:", errors.map(Self.redact))
        print("[\(tag) tool-turn] texto:", text)
        #expect(errors.isEmpty)
        #expect(tools.contains("notes"))
        #expect(text.lowercased().contains("mango-42"))
        #expect(stop == .endTurn)
    }

    @Test func openAIToolTurnSmoke() async throws {
        guard ProcessInfo.processInfo.environment["ANIMA_OPENAI_SMOKE"] == "1" else { return }
        guard let key = key("openai-key") else { print("[openai tool-turn] sin key, skip"); return }
        try await runToolTurn(provider: .openai, key: key, tag: "openai")
    }

    @Test func googleToolTurnSmoke() async throws {
        guard ProcessInfo.processInfo.environment["ANIMA_GOOGLE_SMOKE"] == "1" else { return }
        guard let key = key("google-key") else { print("[google tool-turn] sin key, skip"); return }
        try await runToolTurn(provider: .google, key: key, tag: "google")
    }
}
