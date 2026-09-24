import Foundation
import Testing
@testable import AnimaKit

@Suite struct FirstRunTests {

    // MARK: - Routing del primer arranque

    @Test func routesToLandingWithoutToken() {
        #expect(FirstRunRouter.destination(hasToken: false, hasOnboarded: false) == .landing)
        #expect(FirstRunRouter.destination(hasToken: false, hasOnboarded: true) == .landing)
    }

    @Test func routesToLandingWhenNotOnboarded() {
        #expect(FirstRunRouter.destination(hasToken: true, hasOnboarded: false) == .landing)
    }

    @Test func routesToChatWhenTokenAndOnboarded() {
        #expect(FirstRunRouter.destination(hasToken: true, hasOnboarded: true) == .chat)
    }

    // MARK: - Persistencia del onboarding

    @Test func onboardingDefaultsPersistFlagBudgetAndIntents() throws {
        let suite = "test.anima.firstrun.\(UUID().uuidString)"
        let ud = try #require(UserDefaults(suiteName: suite))
        defer { ud.removePersistentDomain(forName: suite) }
        let store = OnboardingDefaults(defaults: ud)

        #expect(store.hasOnboarded == false)
        #expect(store.monthlyBudgetUSD == nil)
        store.markOnboarded()
        store.setMonthlyBudget(usd: 40)
        store.setPermissionIntents(["calendar", "microphone"])
        #expect(store.hasOnboarded)
        #expect(store.monthlyBudgetUSD == 40)
        #expect(store.permissionIntents == ["calendar", "microphone"])
    }

    // MARK: - Validación de la API key

    @Test func keyValidationRequestCarriesAuthHeaders() throws {
        let api = try TestConfig.providerConfig().api

        let apiKeyReq = try #require(APIKeyValidator.request(token: "sk-ant-api03-xyz", api: api))
        #expect(apiKeyReq.url?.path.hasSuffix("/v1/messages/count_tokens") == true)
        #expect(apiKeyReq.value(forHTTPHeaderField: "x-api-key") == "sk-ant-api03-xyz")
        #expect(apiKeyReq.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

        let oauthReq = try #require(APIKeyValidator.request(token: "sk-ant-oat01-xyz", api: api))
        #expect(oauthReq.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat01-xyz")
        let betas = oauthReq.value(forHTTPHeaderField: "anthropic-beta") ?? ""
        #expect(betas.contains("oauth-2025-04-20"))  // obligatoria con Bearer
    }

    @Test func keyValidationRequestRejectsMalformedToken() throws {
        let api = try TestConfig.providerConfig().api
        #expect(APIKeyValidator.request(token: "sk-foo", api: api) == nil)
    }

    @Test func keyValidationVerdictClassifiesStatuses() {
        #expect(APIKeyValidator.verdict(status: 200, mode: .apiKey) == .valid(.apiKey))
        #expect(APIKeyValidator.verdict(status: 401, mode: .apiKey)
                == .rejected("El API rechazó la key (401: no autenticada)."))
        if case .rejected = APIKeyValidator.verdict(status: 403, mode: .oauth) {} else {
            Issue.record("403 debe rechazar")
        }
        // 5xx no es culpa de la key: aceptar con warning.
        #expect(APIKeyValidator.verdict(status: 529, mode: .oauth) == .offlineAccepted(.oauth))
    }

    // MARK: - Entrevista del Birth

    @Test func birthInterviewAsksOneQuestionAtATime() {
        var interview = BirthInterview()
        #expect(interview.currentQuestion?.id == .name)
        interview.answer("Eco")
        #expect(interview.currentQuestion?.id == .tone)
        interview.answer("Cálido y tranquilo")
        #expect(interview.currentQuestion?.id == .askFirst)
        interview.answer("Pregunta antes de actuar")
        #expect(interview.isComplete)
        #expect(interview.currentQuestion == nil)
    }

    @Test func birthInterviewIgnoresEmptyAnswers() {
        var interview = BirthInterview()
        interview.answer("   ")
        #expect(interview.currentQuestion?.id == .name)
    }

    @Test func skipRemainingFillsSeedDefaults() {
        var interview = BirthInterview()
        interview.answer("Iris")
        interview.skipRemaining()
        #expect(interview.isComplete)
        let birth = interview.birth()
        #expect(birth.name == "Iris")
        #expect(birth.tone == Birth.seed.tone)
    }

    @Test func birthCarriesAnswersIntoSeed() {
        var interview = BirthInterview()
        interview.answer("Eco")
        interview.answer("Sobrio y preciso")
        interview.answer("Actúa y me cuentas")
        let birth = interview.birth()
        #expect(birth.name == "Eco")
        #expect(birth.tone == "Sobrio y preciso")
        #expect(birth.language == "español (es-CO)")
        #expect(birth.values.first?.contains("actúa y me cuentas") == true)
        // El summary card lista key · value en orden.
        #expect(interview.summary.map(\.key) == ["nombre", "tono", "actuar"])
    }

    // MARK: - Siembra del SelfModel

    @Test func seedFromBirthRewritesIdentityAtCyclesZero() async throws {
        let queue = try AnimaDatabase.temporary()
        let model = SelfModel(queue: queue)          // nace con el seed default
        await model.setCycles(12)                    // simula vida previa

        var interview = BirthInterview()
        interview.answer("Eco")
        interview.skipRemaining()
        await model.seed(from: interview.birth())

        let view = await model.view()
        #expect(view.identity.contains("Eco"))
        #expect(await model.cycles() == 0)           // el Birth arranca en 0
        #expect(view.style.contains(Birth.seed.tone))
    }
}
