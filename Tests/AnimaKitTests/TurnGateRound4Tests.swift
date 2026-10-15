import Combine
import Foundation
import Testing
@testable import AnimaKit

/// Provider cuya SEGUNDA llamada queda retenida hasta `release()`.
private final class HoldSecondProvider: Provider, @unchecked Sendable {
    let calls = Locked(0)
    private let gate = Locked<AsyncStream<Void>.Continuation?>(nil)
    private let wait: AsyncStream<Void>

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        wait = stream
        gate.mutate { $0 = continuation }
    }

    func release() { gate.mutate { $0?.finish(); $0 = nil } }

    func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        let n = calls.mutate { $0 += 1; return $0 }
        let wait = self.wait
        return AsyncThrowingStream { c in
            Task {
                if n == 2 { for await _ in wait {} }
                c.yield(.messageStart(id: "m\(n)", model: "x"))
                c.yield(.textDelta("Respuesta \(n)."))
                c.yield(.messageStop)
                c.finish()
            }
        }
    }
}

/// Runner que nunca deja de producir (no respeta la cancelación).
private struct NeverIdleRunner: TurnRunner {
    func run(sessionId: SessionID, content: [ContentBlock], surface: SurfaceID) async -> AsyncStream<LoopEvent> {
        AsyncStream { $0.finish() }
    }
    func waitUntilIdle() async {
        while true { try? await Task.sleep(for: .seconds(60)) }
    }
}

@MainActor
@Suite("Review #38 ronda 4 — la compuerta se suelta con su token, una sola vez")
struct TurnGateRound4Tests {
    private func loopChat(_ provider: Provider) throws -> ChatViewModel {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [], serverTools: [], sleep: { _ in })
        return ChatViewModel(loop: loop, sessionId: try store.startSession())
    }

    // M1: el cierre del turno 1 no suelta la compuerta del turno 2 que el dueño
    // mandó apenas el chat se vio libre.
    @Test func elCierreDeUnTurnoNoSueltaElDelSiguiente() async throws {
        let provider = HoldSecondProvider()
        let chat = try loopChat(provider)
        let gate = TurnGate()
        chat.turnGate = gate
        var second: Task<Void, Never>?
        var fired = false
        let watch = chat.$isStreaming.dropFirst().sink { busy in
            guard !busy, !fired else { return }
            fired = true
            chat.input = "segundo"
            second = Task { await chat.send() }
        }
        chat.input = "primero"
        await chat.send()
        // El turno 2 ya tomó la compuerta y su llamada sigue retenida.
        #expect(await eventually { provider.calls.value == 2 })
        #expect(gate.current == .phoneChat)
        #expect(chat.isStreaming)
        let siri = gate.begin(.siri)
        #expect(siri == nil)
        provider.release()
        await second?.value
        #expect(gate.current == nil)
        #expect(!chat.isStreaming)
        watch.cancel()
    }

    @Test func unTokenSoloSueltaSuTurno() throws {
        let gate = TurnGate()
        let first = try #require(gate.begin(.phoneChat))
        gate.end(first)
        let second = try #require(gate.begin(.phoneChat))
        gate.end(first)                    // end tardío del turno anterior: no hace nada
        #expect(gate.current == .phoneChat)
        gate.end(second)
        #expect(gate.current == nil)
    }

    // m1: tras cancelar un turno de gafas, el reintento espera a que suelte su
    // productor; otra superficie ⇒ ocupado sin esperar.
    @Test func gafasReintentanTrasCancelar() async throws {
        let gate = TurnGate()
        let cancelled = try #require(gate.begin(.glassesHUD))
        // El productor del turno cancelado suelta fuera del main actor.
        Task.detached {
            try? await Task.sleep(for: .milliseconds(80))
            gate.end(cancelled)
        }
        let retried = await GlassesHUDSurface.acquire(gate, wait: .seconds(5))
        #expect(retried != nil)
        if let retried { gate.end(retried) }

        // Otra superficie ⇒ ocupado sin esperar la ventana de reintento (60 s aquí).
        let siri = try #require(gate.begin(.siri))
        let start = ContinuousClock.now
        #expect(await GlassesHUDSurface.acquire(gate, wait: .seconds(60)) == nil)
        #expect(ContinuousClock.now - start < .seconds(20))
        gate.end(siri)
    }

    // m2: un productor que nunca termina no retiene la compuerta para siempre.
    @Test func laEsperaAlProductorTieneTope() async throws {
        let gate = TurnGate()
        let token = try #require(gate.begin(.siri))
        #expect(await TurnGate.waitIdle(NeverIdleRunner(), limit: .milliseconds(50)) == false)
        await gate.end(token, after: NeverIdleRunner(), limit: .milliseconds(50))
        #expect(gate.current == nil)
    }

    // m3: un segundo userTurn del mismo origen no deja una burbuja girando.
    @Test func dosTurnosDelMismoOrigenNoDejanSpinner() async throws {
        let chat = try loopChat(HoldSecondProvider())
        await chat.render(.userTurn(text: "uno", origin: .glassesHUD))
        await chat.render(.userTurn(text: "dos", origin: .glassesHUD))
        #expect(chat.messages.filter(\.isStreaming).count == 1)
        await chat.render(.assistantTurn(text: "Listo.", origin: .glassesHUD))
        #expect(chat.messages.filter(\.isStreaming).isEmpty)
        #expect(chat.messages.map(\.text) == ["uno", "dos", "Listo."])
        #expect(!chat.isStreaming)
    }

    // m5: con la app en background lo encolado no sale; al volver, sí.
    @Test func loEncoladoNoSaleEnBackground() async throws {
        let provider = HoldSecondProvider()
        let chat = try loopChat(provider)
        let gate = TurnGate()
        chat.turnGate = gate
        var foreground = false
        chat.canSendQueued = { foreground }
        chat.usesRemoteConversation = true
        await chat.setOffline(true)
        chat.input = "hola"
        await chat.send()
        await chat.setOffline(false)
        let siri = try #require(gate.begin(.siri))
        gate.end(siri)
        for _ in 0..<20 { await Task.yield() }
        #expect(chat.hasQueuedTurn)
        #expect(provider.calls.value == 0)
        foreground = true
        await chat.resumeQueued()
        #expect(!chat.hasQueuedTurn)
        #expect(provider.calls.value == 1)
    }

    // m6: el observer del chat se quita al reemplazar la compuerta o al re-cablear.
    @Test func elObserverNoSeAcumula() throws {
        let gate = TurnGate()
        let first = try loopChat(HoldSecondProvider())
        first.turnGate = gate
        #expect(gate.observerCount == 1)
        first.detachFromGate()
        let second = try loopChat(HoldSecondProvider())
        second.turnGate = gate
        #expect(gate.observerCount == 1)
        second.turnGate = TurnGate()
        #expect(gate.observerCount == 0)
    }
}

@Suite("Review #38 ronda 4 — voz en vivo con la palabra siguiente a medias")
struct SpeechRound4Tests {
    private func said(_ deltas: [String]) -> [String] {
        var segmenter = StreamingSentenceSegmenter()
        var out: [String] = []
        for delta in deltas { out += segmenter.feed(delta) }
        return out + segmenter.finish()
    }

    @Test func pmPartidoEntreDeltas() {
        #expect(said(["Llego a las 4 p. m", ". Te aviso."]) == ["Llego a las 4 p. m.", "Te aviso."])
        #expect(said(["Llego a las 4 a. ", "m. y te aviso."]) == ["Llego a las 4 a. m. y te aviso."])
    }

    @Test func pEjPartidoEntreDeltas() {
        #expect(said(["Usa algo, p. e", "j. una lista. Bien."]) == ["Usa algo, p. ej. una lista.", "Bien."])
        #expect(said(["Usa algo, p. ej", ". una lista. Bien."]) == ["Usa algo, p. ej. una lista.", "Bien."])
    }

    @Test func unaLetraSueltaCompletaSiCorta() {
        #expect(said(["Opción p. ", "Mejor la otra."]) == ["Opción p.", "Mejor la otra."])
    }
}
