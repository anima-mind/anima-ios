// ConversationCompactor.swift — "Compactar" del medidor de contexto (batch 5b
// #4/#5), como en Claude Code: la conversación de la sesión se resume con el
// córtex de ciclo (.consolidation: Claude en remoto/híbrido) y el resumen abre
// la ventana desde ahí; los turnos viejos siguen en el transcript (la noche los
// ve), fuera del contexto. En Solo teléfono se resume por trozos ≤ 2k tokens
// con el modelo local; si algo falla, cae al recorte duro (nunca se queda a
// medias).

import Foundation

public struct ConversationCompactor: Sendable {
    public enum Outcome: Sendable, Equatable {
        case compacted(summary: String)
        case trimmed
        case nothingToDo
    }

    /// Trozo máximo para el modelo local (~2k tokens).
    public static let localChunkChars = 7000
    /// Turnos que conserva el recorte duro de respaldo.
    public static let fallbackKeepTurns = 4
    public static let system = """
        Resume la conversación entre tú (Anima) y el dueño para poder seguirla sin el texto original. \
        En español, en primera persona ("hablamos de…", "le propuse…"), máximo 12 viñetas: hechos, \
        decisiones, pendientes y el tono. Nada inventado. Solo el resumen.
        """

    private let selector: ProviderSelector
    private let store: SymbolicStore
    private let telemetry: Telemetry?

    public init(selector: ProviderSelector, store: SymbolicStore, telemetry: Telemetry? = nil) {
        self.selector = selector
        self.store = store
        self.telemetry = telemetry
    }

    public func compact(sessionId: SessionID) async throws -> Outcome {
        let previous = try store.currentBoundary(sessionId: sessionId)
        let transcript = Self.transcript(try store.window(sessionId: sessionId))
        guard !transcript.isEmpty else { return .nothingToDo }
        let nextSeq = try store.lastSeq(sessionId: sessionId) + 1
        do {
            let summary = try await summarize(transcript, carrying: previous?.summary)
            guard !summary.isEmpty else { throw ClassifiedError.fatal(status: -1, message: "resumen vacío") }
            try store.addBoundary(sessionId: sessionId, kind: .compaction, fromSeq: nextSeq, summary: summary)
            return .compacted(summary: summary)
        } catch {
            let from = try store.trimStart(sessionId: sessionId, keepTurns: Self.fallbackKeepTurns)
            try store.addBoundary(sessionId: sessionId, kind: .trim, fromSeq: from, summary: previous?.summary,
                                  model: selector.binding(for: .consolidation).map { ModelNames.friendly($0.router.route(.consolidation).model) })
            return .trimmed
        }
    }

    /// "Dueño: …" / "Anima: …" con solo el texto (sin tools ni razonamiento).
    static func transcript(_ messages: [Message]) -> String {
        messages.compactMap { message -> String? in
            let text = message.content.compactMap { block -> String? in
                if case .text(let t) = block { return t } else { return nil }
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix(ContextBoundary.summaryHeader) else { return nil }
            switch message.role {
            case .user: return "Dueño: \(text)"
            case .assistant: return "Anima: \(text)"
            default: return nil
            }
        }.joined(separator: "\n\n")
    }

    static func chunks(_ text: String, size: Int) -> [String] {
        guard text.count > size else { return [text] }
        var out: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            if !current.isEmpty, current.count + paragraph.count + 2 > size {
                out.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n\n") + String(paragraph.prefix(size))
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private func summarize(_ transcript: String, carrying previous: String?) async throws -> String {
        guard let binding = selector.binding(for: .consolidation) else {
            throw ClassifiedError.fatal(status: -1, message: "sin córtex para compactar")
        }
        let input = (previous.map { "Resumen anterior:\n\($0)\n\n" } ?? "") + transcript
        let pieces = binding.backend == .onDevice ? Self.chunks(input, size: Self.localChunkChars) : [input]
        var partials: [String] = []
        for piece in pieces { partials.append(try await call(binding, piece)) }
        guard partials.count > 1 else { return partials.first ?? "" }
        let joined = partials.joined(separator: "\n")
        return joined.count <= Self.localChunkChars ? try await call(binding, joined) : joined
    }

    private func call(_ binding: ProviderBinding, _ text: String) async throws -> String {
        let route = binding.router.route(.consolidation)
        let opts = binding.callOpts(route: ModelRoute(model: route.model, effort: nil, maxTokens: min(route.maxTokens, 1200)),
                                    systemPromptBase: Self.system)
        let response = try await binding.provider.completeCollecting(AssembledContext(messages: [.user(text)]),
                                                                     tools: [], opts: opts)
        try? telemetry?.record(sessionId: "compactor", turnClass: .consolidation, model: route.model,
                               usage: response.usage, toolCalls: 0, retries: 0)
        return response.content.compactMap { block -> String? in
            if case .text(let t) = block { return t } else { return nil }
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
