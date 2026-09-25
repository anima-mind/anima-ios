import Foundation
import Testing
import GRDB
@testable import AnimaKit

@Suite struct SleepSchedulerTests {

    private static let reflection = [ProviderEvent].text(#"{"summary":"nada nuevo","insights":[]}"#)

    private func consolidator(_ scripts: [[ProviderEvent]]) throws -> (Consolidator, DatabaseQueue) {
        let queue = try AnimaDatabase.temporary()
        let brain = Brain(queue: queue, embedder: Embedder(forceFallback: true))
        let c = Consolidator(brain: brain, queue: queue, provider: ScriptedProvider(scripts),
                             router: try .haikuAll(), authMode: .apiKey, token: "sk-ant-api03-x")
        return (c, queue)
    }

    // MARK: Política del fallback foreground (48h)

    @Test func foregroundFallbackPolicy() {
        let scheduler = SleepScheduler()
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(scheduler.shouldRunForegroundFallback(lastCycleAt: nil, now: now))  // nunca soñó
        #expect(!scheduler.shouldRunForegroundFallback(lastCycleAt: now.addingTimeInterval(-47 * 3600), now: now))
        #expect(!scheduler.shouldRunForegroundFallback(lastCycleAt: now.addingTimeInterval(-48 * 3600), now: now))
        #expect(scheduler.shouldRunForegroundFallback(lastCycleAt: now.addingTimeInterval(-48 * 3600 - 1), now: now))

        let short = SleepScheduler(foregroundFallbackInterval: 60)
        #expect(short.shouldRunForegroundFallback(lastCycleAt: now.addingTimeInterval(-61), now: now))
    }

    @Test func defaultsRequirePowerAndNetwork() {
        let s = SleepScheduler()
        #expect(s.requiresExternalPower)
        #expect(s.requiresNetworkConnectivity)
        #expect(s.foregroundFallbackInterval == 48 * 3600)
        #expect(SleepScheduler.taskIdentifier == "mind.anima.consolidate")
    }

    // MARK: Ejecución reanudable

    @Test func runResumableCompletesCycle() async throws {
        let (c, _) = try consolidator([Self.reflection])
        #expect(await SleepScheduler().runResumable(c))
    }

    @Test func expirationCutsAtStageBoundaryAndResumes() async throws {
        let (c, _) = try consolidator([Self.reflection])
        let flag = ExpirationFlag()
        #expect(!flag.value)
        flag.mark()  // iOS disparó el expirationHandler
        #expect(flag.value)
        #expect(await SleepScheduler().runResumable(c, isExpired: { flag.value }) == false)
        // La siguiente ventana retoma y termina.
        #expect(await SleepScheduler().runResumable(c))
    }

    @Test func runResumableReportsFailureOnError() async throws {
        let (c, queue) = try consolidator([])
        try await queue.write { try $0.execute(sql: "DROP TABLE consolidation_cycle") }
        #expect(await SleepScheduler().runResumable(c) == false)
    }

    // MARK: Holder (runner BGTask → Consolidator cableado tarde)

    @Test func holderWithoutConsolidatorIsNoOp() async {
        #expect(await ConsolidatorHolder().run(isExpired: { false }) == false)
    }

    @Test func holderRunsWiredConsolidator() async throws {
        let (c, _) = try consolidator([Self.reflection])
        let holder = ConsolidatorHolder()
        holder.set(c, scheduler: SleepScheduler())
        #expect(await holder.run(isExpired: { false }))
    }
}
