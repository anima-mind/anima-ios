import Foundation
import Testing
@testable import AnimaKit

@MainActor
@Suite struct OnboardingFlowTests {

    private func makeModel(account: AccountViewModel? = nil) throws -> (OnboardingViewModel, UserDefaults, String) {
        let suite = "test.anima.onboarding.\(UUID().uuidString)"
        let ud = try #require(UserDefaults(suiteName: suite))
        let model = OnboardingViewModel(
            keychain: KeychainStore(service: "test.anima.onboarding.\(UUID().uuidString)"),
            api: nil,
            selfModel: nil,
            defaults: OnboardingDefaults(defaults: ud),
            account: account) {}
        return (model, ud, suite)
    }

    @Test func onboardingHasSevenStepsWithAccountBeforeProvider() {
        #expect(OnboardingViewModel.stepCount == 7)
        #expect(OnboardingViewModel.Step.allCases == [
            .tutorial, .account, .provider, .apiKey, .permissions, .glasses, .birth,
        ])
    }

    @Test func tutorialAdvancesToAccount() throws {
        let (model, ud, suite) = try makeModel()
        defer { ud.removePersistentDomain(forName: suite) }
        #expect(model.step == .tutorial)
        model.advance()
        #expect(model.step == .account)
        #expect(model.progressIndex == 1)
    }

    @Test func skippingAccountContinuesToProvider() throws {
        let (model, ud, suite) = try makeModel()
        defer { ud.removePersistentDomain(forName: suite) }
        model.advance()
        #expect(model.account.state == .unavailable)   // sin proveedor: jamás bloquea
        model.skipAccount()
        #expect(model.step == .provider)
        #expect(model.account.state.isSignedIn == false)
    }

    @Test func skipIsIgnoredOutsideAccountStep() throws {
        let (model, ud, suite) = try makeModel()
        defer { ud.removePersistentDomain(forName: suite) }
        model.skipAccount()
        #expect(model.step == .tutorial)
    }

    @Test func signedInAccountContinuesToProvider() async throws {
        let account = AccountViewModel(provider: PreviewAccountProvider())
        let (model, ud, suite) = try makeModel(account: account)
        defer { ud.removePersistentDomain(forName: suite) }
        model.advance()
        await model.account.signIn(with: AppleCredential(idToken: "id", rawNonce: "n"))
        #expect(model.account.state.isSignedIn)
        #expect(model.step == .account)                // el dueño ve la fila con check
        model.advance()
        #expect(model.step == .provider)
    }

    @Test func failedSignInStillAllowsSkip() async throws {
        let provider = PreviewAccountProvider()
        provider.signInError = .network
        let account = AccountViewModel(provider: provider)
        let (model, ud, suite) = try makeModel(account: account)
        defer { ud.removePersistentDomain(forName: suite) }
        model.advance()
        await model.account.signIn(with: AppleCredential(idToken: "id", rawNonce: "n"))
        #expect(model.account.notice != nil)
        model.skipAccount()
        #expect(model.step == .provider)
    }

    @Test func backFromAccountReturnsToTutorial() throws {
        let (model, ud, suite) = try makeModel()
        defer { ud.removePersistentDomain(forName: suite) }
        model.advance()
        #expect(model.goBack() == false)
        #expect(model.step == .tutorial)
        #expect(model.goBack() == true)
    }
}
