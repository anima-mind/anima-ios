import Foundation
import Testing
@testable import AnimaKit

// Campo batch 3 / FIX F: Ajustes como hub con resumen vivo por fila.

@Suite("Campo — Ajustes hub")
struct SettingsHubTests {
    @Test func gastoDelMesSoloCuentaDesdeElInicio() throws {
        let queue = try AnimaDatabase.temporary()
        let telemetry = Telemetry(queue: queue)
        try telemetry.record(sessionId: "s", turnClass: .interactive, model: "claude-haiku-4-5",
                             usage: Usage(inputTokens: 1_000_000, outputTokens: 0), toolCalls: 0, retries: 0)
        try queue.write { try $0.execute(sql: "UPDATE turn_telemetry SET ts = 0") }   // mes viejo
        try telemetry.record(sessionId: "s", turnClass: .interactive, model: "claude-haiku-4-5",
                             usage: Usage(inputTokens: 1_000_000, outputTokens: 0), toolCalls: 0, retries: 0)
        let month = try telemetry.costUSD(since: Date(timeIntervalSince1970: 1))
        let total = try telemetry.totalCostUSD()
        #expect(month > 0)
        #expect(abs(total - 2 * month) < 1e-9)
    }

    #if canImport(SwiftUI)
    @MainActor
    @Test func resumenesDeModeloYMente() async throws {
        let ud = try #require(UserDefaults(suiteName: "test.hub.\(UUID().uuidString)"))
        let queue = try AnimaDatabase.temporary()
        let model = SettingsViewModel(keychain: ProviderTokenStore(service: "svc", backend: InMemoryKeychain()),
                                      telemetry: Telemetry(queue: queue),
                                      onboardingDefaults: OnboardingDefaults(defaults: ud), availability: { .available })
        model.load()
        #expect(model.modelSummary.hasSuffix("$0.00 este mes"))
        await model.refreshMind()
        #expect(model.mindSummary == "")
        let selfModel = SelfModel(queue: queue)
        await selfModel.setCycles(3)
        model.selfModel = selfModel
        await model.refreshMind()
        #expect(model.mindSummary == SettingsViewModel.mindLine(cycles: 3))
        #expect(SettingsViewModel.mindLine(cycles: 0) == "ciclo #0 · p 1.00")
        let start = SettingsViewModel.startOfMonth(Date(timeIntervalSince1970: 1_760_000_000))
        #expect(Calendar.current.component(.day, from: start) == 1)
    }
    #endif
}
