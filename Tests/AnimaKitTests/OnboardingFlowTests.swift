import Foundation
import Testing
@testable import AnimaKit

@MainActor
@Suite struct OnboardingFlowTests {

    private func makeModel(account: AccountViewModel? = nil,
                           availability: OnDeviceAvailability = .unknown) throws -> (OnboardingViewModel, UserDefaults, String) {
        let suite = "test.anima.onboarding.\(UUID().uuidString)"
        let ud = try #require(UserDefaults(suiteName: suite))
        let model = OnboardingViewModel(
            keychain: ProviderTokenStore(service: "test.anima.onboarding.\(UUID().uuidString)"),
            selfModel: nil,
            defaults: OnboardingDefaults(defaults: ud),
            account: account,
            availability: { availability }) {}
        return (model, ud, suite)
    }

    private func goToProvider(_ model: OnboardingViewModel) {
        model.advance()        // → account
        model.skipAccount()    // → provider
    }

    // MARK: Modo gratis on-device (§4.9)

    @Test func onDeviceChoiceSkipsAPIKeyStep() throws {
        let (model, ud, suite) = try makeModel(availability: .available)
        defer { ud.removePersistentDomain(forName: suite) }
        goToProvider(model)
        model.selectProvider(.onDevice)
        #expect(model.selectedProvider == .onDevice)
        #expect(model.canLeaveProviderStep)
        model.advance()
        #expect(model.step == .permissions)   // sin paso de API key
        #expect(OperatingModeStore(defaults: ud).mode == .onDeviceOnly)
        // Back desde permisos vuelve al provider (la key nunca se vio).
        model.goBack()
        #expect(model.step == .provider)
    }

    @Test func unavailableOnDeviceCannotBeChosen() throws {
        let (model, ud, suite) = try makeModel(availability: .deviceNotEligible)
        defer { ud.removePersistentDomain(forName: suite) }
        goToProvider(model)
        model.selectProvider(.onDevice)
        #expect(model.selectedProvider == .anthropic)
        #expect(model.onDeviceAvailability.reason != nil)   // la UI muestra el porqué
        model.advance()
        #expect(model.step == .apiKey)
    }

    @Test func anthropicWithTokenOffersHybridDefaultOn() throws {
        let (model, ud, suite) = try makeModel(availability: .available)
        defer { ud.removePersistentDomain(forName: suite) }
        goToProvider(model)
        model.advance()
        #expect(model.step == .apiKey)
        #expect(!model.offersHybrid)                  // sin token aún
        model.keyStatus = .valid(.apiKey)
        #expect(model.offersHybrid)
        #expect(model.hybridEnabled)                  // default ON con availability
        model.advance()
        #expect(model.step == .permissions)
        #expect(OperatingModeStore(defaults: ud).mode == .hybrid)
    }

    @Test func hybridOffPersistsClaudeMode() throws {
        let (model, ud, suite) = try makeModel(availability: .available)
        defer { ud.removePersistentDomain(forName: suite) }
        goToProvider(model)
        model.advance()
        model.keyStatus = .offline(.oauth)
        model.hybridEnabled = false
        model.advance()
        #expect(OperatingModeStore(defaults: ud).mode == .remote)
    }

    @Test func withoutLocalModelHybridIsNotOffered() throws {
        let (model, ud, suite) = try makeModel(availability: .modelNotReady)
        defer { ud.removePersistentDomain(forName: suite) }
        goToProvider(model)
        model.advance()
        model.keyStatus = .valid(.apiKey)
        #expect(!model.offersHybrid)
        #expect(!model.hybridEnabled)
        model.advance()
        #expect(OperatingModeStore(defaults: ud).mode == .remote)
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
