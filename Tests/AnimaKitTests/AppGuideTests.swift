import Foundation
import Testing
@testable import AnimaKit

// Campo batch 5 #12: "no tiene contexto de cómo funciona el app". El mapa de la
// app va en el system base de cada turno del chat, en código (prefijo cacheado).

@Suite struct AppGuideTests {
    @Test func namesEveryTabAndEverySettingsRowByItsVisibleName() {
        for tab in ShellTab.allCases {
            #expect(AppGuide.block.contains(tab.title), "falta la tab \(tab.title)")
        }
        for route in SettingsRoute.allCases {
            #expect(AppGuide.block.contains(route.title), "falta la fila \(route.title)")
        }
        for concept in ["Recordatorios", "Solo este teléfono", "Híbrido", "Enséñame algo", "Simular una noche",
                        "Avisos de Anima", "Por aprobar", "noches de consolidación", "confirmación", "guíalo",
                        "Seguimiento", "Seguimientos", "Programados", "Autorizar siempre", "Permisos", "Compactar",
                        "Nueva conversación", "Contexto", "Marcar lograda", "Eliminar", "Historial", "Hecho",
                        "Cancelar"] {
            #expect(AppGuide.block.contains(concept), "falta \(concept)")
        }
        #expect(!AppGuide.block.localizedCaseInsensitiveContains("check-in"), "la UI dice Seguimiento")
        #expect(!AppGuide.compactBlock.localizedCaseInsensitiveContains("check-in"))
    }

    @Test func staysCompact() {
        // ~250-350 tokens (heurística chars/4 del store).
        #expect(AppGuide.block.count / 4 <= 350)
        #expect(AppGuide.block.count / 4 >= 200)
    }

    @Test func appendsToTheRemoteConfigBase() {
        #expect(AppGuide.systemBase("") == AppGuide.block)
        #expect(AppGuide.systemBase("Eres Anima.") == "Eres Anima.\n\n" + AppGuide.block)
    }

    final class SystemCapture: Provider, @unchecked Sendable {
        let bases = Locked<[String]>([])
        func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
            -> AsyncThrowingStream<ProviderEvent, Error> {
            bases.mutate { $0.append(opts.systemPromptBase) }
            return AsyncThrowingStream { continuation in
                continuation.yield(.textDelta("ok"))
                continuation.yield(.messageDelta(stopReason: .endTurn, usage: Usage(inputTokens: 1, outputTokens: 1)))
                continuation.yield(.messageStop)
                continuation.finish()
            }
        }
    }

    @Test func everyChatTurnCarriesTheGuideInTheStableBase() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let provider = SystemCapture()
        let config = try TestConfig.providerConfig()
        let loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: config), authMode: .apiKey, token: "sk-ant-api03-xyz",
                             clientTools: [], serverTools: [], sleep: { _ in })
        let sid = try store.startSession()
        for await _ in await loop.run(sessionId: sid, userText: "¿dónde veo mis recordatorios?") {}
        for await _ in await loop.run(sessionId: sid, userText: "gracias") {}
        let bases = provider.bases.value
        #expect(bases.count == 2)
        #expect(bases.allSatisfy { $0 == AppGuide.systemBase(config.systemPromptBase) })
    }
}
