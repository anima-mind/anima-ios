import Foundation
import Testing
@testable import AnimaKit

// Revisión batch 5: una acción "Hecho"/"En 1 hora" desde el push con red lenta
// no puede quedar esperando el fetch de Remote Config (iOS mata el handler).

@Suite struct RemoteConfigFetchTests {
    /// El fetch no termina hasta que el test lo suelta: si `run` vuelve, fue por
    /// el tope (sin umbrales de reloj: la suite corre en paralelo y bajo carga).
    @Test func slowFetchIsCutAtTheTimeoutAndKeepsRunning() async {
        let released = Locked(false)
        let finished = Locked(false)
        let onTime = await RemoteConfigFetch.run(timeout: 0.05) {
            while !released.value { try? await Task.sleep(nanoseconds: 5_000_000) }
            finished.mutate { $0 = true }
        }
        #expect(!onTime)
        #expect(!finished.value)
        released.mutate { $0 = true }
        for _ in 0..<400 where !finished.value { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(finished.value)
    }

    @Test func fastFetchReturnsAsSoonAsItEnds() async {
        #expect(await RemoteConfigFetch.run(timeout: 600) {})
    }

    @Test func withoutTimeoutWaitsForTheFetch() async {
        let finished = Locked(false)
        #expect(await RemoteConfigFetch.run(timeout: nil) {
            try? await Task.sleep(nanoseconds: 50_000_000)
            finished.mutate { $0 = true }
        })
        #expect(finished.value)
        #expect(RemoteConfigFetch.notificationActionTimeout <= 3)
    }
}
