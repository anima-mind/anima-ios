import Foundation
import Testing
@testable import AnimaKit

@Suite struct ModelRouterTests {

    @Test func interactiveRoutesToOpusMediumFromConfig() throws {
        let router = ModelRouter(config: try TestConfig.providerConfig())
        let route = router.route(.interactive)
        #expect(route.model == "claude-opus-4-8")
        #expect(route.effort == "medium")
        #expect(route.maxTokens == 16000)
    }

    @Test func interactiveHardRoutesToOpusHigh() throws {
        let router = ModelRouter(config: try TestConfig.providerConfig())
        let route = router.route(.interactiveHard)
        #expect(route.model == "claude-opus-4-8")
        #expect(route.effort == "high")
        #expect(route.maxTokens == 32000)
    }

    @Test func consolidationRoutesToHaikuNoEffort() throws {
        let router = ModelRouter(config: try TestConfig.providerConfig())
        let route = router.route(.consolidation)
        #expect(route.model == "claude-haiku-4-5")
        #expect(route.effort == nil)
    }

    @Test func unknownTurnFallsBackToInteractive() throws {
        // La config de test no define desirePulse → cae a interactive.
        let router = ModelRouter(config: try TestConfig.providerConfig())
        let route = router.route(.desirePulse)
        #expect(route.model == "claude-opus-4-8")
    }

    @Test func paramPolicyForbidsEffortOnHaiku() {
        let opus = ModelParamPolicy.policy(for: "claude-opus-4-8")
        #expect(opus.allowsEffort)
        #expect(opus.allowsThinking)
        let haiku = ModelParamPolicy.policy(for: "claude-haiku-4-5")
        #expect(!haiku.allowsEffort)
    }
}
