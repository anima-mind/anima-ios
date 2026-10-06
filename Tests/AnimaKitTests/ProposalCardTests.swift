import Foundation
import Testing
@testable import AnimaKit

// Batch 5b #3: "le di aprobar pero no sé qué pasó". "Hagámoslo" acepta Y le
// pide a ella que lo haga; "Ahora no" la descarta; el estado queda visible.

@MainActor
@Suite struct ProposalCardTests {
    @Test func letsDoItAcceptsAndAsksHerToActNowNotDismisses() async throws {
        let queue = try AnimaDatabase.temporary()
        let other = OtherModel(queue: queue)
        let store = SymbolicStore(queue: queue)
        let engine = DesireEngine(otherModel: other, environment: MockObservableEnvironment(workouts: 0),
                                  queue: queue, provider: MockProvider(events: .text("¿Agendo 45 min para entrenar?")),
                                  router: try .haikuAll(), authMode: .apiKey, token: "sk-ant-api03-x")
        _ = await other.ingestStated(statement: "entrenar", desiredState: .workoutsPerWeek(atLeast: 3), evidence: "e")
        _ = await other.ingestStated(statement: "leer", desiredState: .progressCheckIn(everyDays: 1), evidence: "e")
        let intentions = try await engine.pulse()
        #expect(!intentions.isEmpty)

        let provider = CapturingProvider([.text("Listo, te bloqueé 45 min mañana a las 7.")])
        let loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [], serverTools: [], sleep: { _ in })
        let chat = ChatViewModel(loop: loop, sessionId: try store.startSession(), desireEngine: engine)
        await chat.loadProactiveIntentions()
        let card = try #require(chat.messages.first { $0.intentionId != nil })
        #expect(chat.cardLabel(card) == "Propuesta de \(Birth.seed.name)")

        await chat.accept(card)
        let resolved = try #require(chat.messages.first { $0.id == card.id })
        #expect(resolved.outcome == .accepted && resolved.resolved)
        #expect(chat.messages.contains { $0.role == .user && $0.text == "Acepto: \(card.text)" })
        let sent = try #require(provider.captures.value.first?.messages.last)
        #expect(sent == .user("Acepto: \(card.text)"))
        #expect(chat.messages.last?.text == "Listo, te bloqueé 45 min mañana a las 7.")
        #expect(await engine.intention(id: card.intentionId ?? "")?.outcome == .accepted)

        if let second = chat.messages.first(where: { $0.intentionId != nil && $0.id != card.id }) {
            await chat.dismiss(second)
            #expect(chat.messages.first { $0.id == second.id }?.outcome == .dismissed)
            #expect(provider.captures.value.count == 1)              // "Ahora no" no le pide nada
        }
        #expect(ChatViewModel.acceptText("x") == "Acepto: x")
        #expect(ProactiveCard.label(.intention(id: "i"), at: nil, goalStatement: nil, now: Date(),
                                    dates: AnimaDateText(), selfName: "Budosky") == "Propuesta de Budosky")
    }
}
