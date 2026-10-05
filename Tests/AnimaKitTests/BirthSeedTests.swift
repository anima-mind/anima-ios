import Foundation
import Testing
@testable import AnimaKit

/// La siembra del Birth resuelve el SelfModel al terminar, no al crear el modelo:
/// en un device lento el landing se toca antes de que el bootstrap termine, y
/// capturar `nil` perdía el nombre (header "Anima" en vez del elegido).
@MainActor
@Suite struct BirthSeedTests {

    private func makeModel(selfModel: SelfModel?,
                           resolver: (@Sendable () async -> SelfModel?)?,
                           onFinished: @escaping () -> Void) throws -> (OnboardingViewModel, UserDefaults, String) {
        let suite = "test.anima.birth.\(UUID().uuidString)"
        let ud = try #require(UserDefaults(suiteName: suite))
        let model = OnboardingViewModel(
            keychain: ProviderTokenStore(service: "test.anima.birth.\(UUID().uuidString)"),
            selfModel: selfModel,
            selfModelResolver: resolver,
            defaults: OnboardingDefaults(defaults: ud),
            availability: { .available },
            onFinished: onFinished)
        return (model, ud, suite)
    }

    @Test func seedUsesTheSelfModelResolvedAtFinishTime() async throws {
        let selfModel = SelfModel(queue: try AnimaDatabase.temporary())
        let finished = ExpirationFlag()
        let (model, ud, suite) = try makeModel(selfModel: nil, resolver: { selfModel }) { finished.mark() }
        defer { ud.removePersistentDomain(forName: suite) }

        model.answerBirth("Iris")
        model.skipRest()
        model.finish(reseed: true)

        #expect(await eventually { finished.value })
        #expect(await selfModel.name() == "Iris")
    }

    @Test func withoutResolverTheCapturedSelfModelStillSeeds() async throws {
        let selfModel = SelfModel(queue: try AnimaDatabase.temporary())
        let finished = ExpirationFlag()
        let (model, ud, suite) = try makeModel(selfModel: selfModel, resolver: nil) { finished.mark() }
        defer { ud.removePersistentDomain(forName: suite) }

        model.answerBirth("Nova")
        model.skipRest()
        model.finish(reseed: true)

        #expect(await eventually { finished.value })
        #expect(await selfModel.name() == "Nova")
    }

    @Test func replayWithoutReseedKeepsTheExistingName() async throws {
        let selfModel = SelfModel(queue: try AnimaDatabase.temporary())
        await selfModel.seed(from: Birth(name: "Iris", tone: "Cálido y tranquilo", language: "es", values: []))
        let finished = ExpirationFlag()
        let (model, ud, suite) = try makeModel(selfModel: nil, resolver: { selfModel }) { finished.mark() }
        defer { ud.removePersistentDomain(forName: suite) }

        model.answerBirth("Otra")
        model.skipRest()
        model.finish(reseed: false)

        #expect(await eventually { finished.value })
        #expect(await selfModel.name() == "Iris")
    }
}
