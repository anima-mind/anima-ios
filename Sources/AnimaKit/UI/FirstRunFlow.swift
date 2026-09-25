// FirstRunFlow.swift — lógica pura de la experiencia de primer arranque:
// routing (landing/chat), validación de la API key contra el endpoint gratuito
// count_tokens, la entrevista conversacional del Birth (paso 6) y la siembra
// del SelfModel. Sin SwiftUI: todo testeable en swift test.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Routing del primer arranque

public enum FirstRunDestination: Sendable, Equatable {
    case landing   // primera vez: intro → onboarding
    case chat      // ya nació: directo al shell
}

public enum FirstRunRouter {
    /// Landing si no hay token en Keychain o el onboarding no se completó
    /// (el SelfModel "no ha nacido" mientras el Birth no corra).
    public static func destination(hasToken: Bool, hasOnboarded: Bool) -> FirstRunDestination {
        (hasToken && hasOnboarded) ? .chat : .landing
    }
}

/// Persistencia liviana del onboarding (flags y presupuesto, NUNCA secretos —
/// el token vive en Keychain). @unchecked: UserDefaults es thread-safe pero no
/// declara Sendable.
public struct OnboardingDefaults: @unchecked Sendable {
    public static let onboardedKey = "anima.onboarded"
    public static let budgetKey = "anima.monthlyBudgetUSD"
    public static let permissionIntentsKey = "anima.permissionIntents"

    /// Chips de presupuesto mensual del paso API key (handoff §Onboarding).
    public static let budgetOptions = [10, 20, 40, 100]

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hasOnboarded: Bool {
        defaults.bool(forKey: Self.onboardedKey)
    }

    public func markOnboarded(_ done: Bool = true) {
        defaults.set(done, forKey: Self.onboardedKey)
    }

    public var monthlyBudgetUSD: Int? {
        let value = defaults.integer(forKey: Self.budgetKey)
        return value > 0 ? value : nil
    }

    public func setMonthlyBudget(usd: Int) {
        defaults.set(usd, forKey: Self.budgetKey)
    }

    /// Intención de permisos (paso 4): NO son los permisos TCC — el prompt real
    /// sale al primer uso (PermissionPolicy). Aquí solo la intención del dueño.
    public var permissionIntents: Set<String> {
        Set(defaults.stringArray(forKey: Self.permissionIntentsKey) ?? [])
    }

    public func setPermissionIntents(_ intents: Set<String>) {
        defaults.set(Array(intents).sorted(), forKey: Self.permissionIntentsKey)
    }

    /// El modo de operación (§4.9) vive en el mismo dominio de defaults.
    public var modeStore: OperatingModeStore {
        OperatingModeStore(defaults: defaults)
    }

    /// Qué provider remoto está activo (Anthropic/OpenAI/Google).
    public var remoteStore: RemoteProviderStore {
        RemoteProviderStore(defaults: defaults)
    }
}

// MARK: - Validación de la API key (paso 3)

/// Valida el token contra el API real con el request más barato que existe:
/// POST /v1/messages/count_tokens (gratis, requiere auth). 200 → válida;
/// 401/403 → rechazada; sin red / 5xx → se acepta con warning (offline).
public struct APIKeyValidator: Sendable {

    public enum Verdict: Sendable, Equatable {
        case valid(AuthMode)
        case rejected(String)           // el API la rechazó (401/403/4xx)
        case offlineAccepted(AuthMode)  // formato ok, sin red: aceptar con warning
        case malformed                  // prefijo no reconocido (ni api ni oat)
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Request mínimo de validación (puro, testeable): count_tokens con un
    /// mensaje de un token. Headers de auth según el AuthMode detectado y las
    /// betas efectivas del modo (oauth exige su beta).
    public static func request(token: String, api: ProviderAPIConfig,
                               model: String = "claude-haiku-4-5") -> URLRequest? {
        guard let mode = AuthMode.detect(fromToken: token) else { return nil }
        var req = URLRequest(url: api.baseURL.appendingPathComponent("v1/messages/count_tokens"))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let version = api.version {
            req.setValue(version, forHTTPHeaderField: "anthropic-version")
        }
        switch mode {
        case .apiKey: req.setValue(token, forHTTPHeaderField: "x-api-key")
        case .oauth: req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let betas = api.effectiveBetas(for: mode)
        if !betas.isEmpty {
            req.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        let body: JSONValue = .object([
            "model": .string(model),
            "messages": .array([.object(["role": .string("user"), "content": .string("ping")])]),
        ])
        req.httpBody = try? JSONEncoder().encode(body)
        return req
    }

    /// Clasificación pura del status HTTP (testeable sin red).
    public static func verdict(status: Int, mode: AuthMode) -> Verdict {
        switch status {
        case 200..<300: return .valid(mode)
        case 401: return .rejected("El API rechazó la key (401: no autenticada).")
        case 403: return .rejected("La key no tiene permiso (403).")
        case 400..<500: return .rejected("El API respondió \(status).")
        default: return .offlineAccepted(mode)  // 5xx/529: no es culpa de la key
        }
    }

    /// Validación de una key OpenAI-compat (OpenAI y Gemini): GET {base}/models
    /// con Bearer — gratis y exige auth.
    public static func compatRequest(token: String, api: ProviderAPIConfig) -> URLRequest {
        var req = URLRequest(url: api.baseURL.appendingPathComponent("models"))
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// Validación por provider: Anthropic por count_tokens; OpenAI/Google por
    /// /models. Sin red → se acepta con warning (como Anthropic).
    public func validate(token: String, provider: ModelProvider, api: ProviderAPIConfig) async -> Verdict {
        guard provider.usesOpenAICompatWire else { return await validate(token: token, api: api) }
        guard provider.acceptsTokenFormat(token) else { return .malformed }
        do {
            let (_, response) = try await session.data(for: Self.compatRequest(token: token, api: api))
            guard let http = response as? HTTPURLResponse else { return .offlineAccepted(.apiKey) }
            return Self.verdict(status: http.statusCode, mode: .apiKey)
        } catch {
            return .offlineAccepted(.apiKey)
        }
    }

    /// Validación completa contra el API real.
    public func validate(token: String, api: ProviderAPIConfig) async -> Verdict {
        guard let mode = AuthMode.detect(fromToken: token) else { return .malformed }
        guard let request = Self.request(token: token, api: api) else { return .malformed }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .offlineAccepted(mode) }
            return Self.verdict(status: http.statusCode, mode: mode)
        } catch {
            return .offlineAccepted(mode)  // sin red: aceptar con warning
        }
    }
}

// MARK: - Entrevista conversacional del Birth (paso 6)

/// El Birth NO es un formulario: Anima pregunta una a una (mind messages) y el
/// dueño responde con chips o texto. Máquina de estados pura.
public struct BirthInterview: Sendable, Equatable {

    public enum StepID: String, Sendable, CaseIterable, Equatable {
        case name, tone, askFirst
    }

    public struct Question: Sendable, Equatable {
        public let id: StepID
        public let prompt: String       // el mind message que Anima streamea
        public let chips: [String]      // sugerencias
        public let summaryKey: String   // etiqueta en la summary card
    }

    public static let questions: [Question] = [
        Question(id: .name,
                 prompt: "Estoy naciendo. Lo primero: ¿cómo quieres llamarme?",
                 chips: ["Anima", "Eco", "Iris"],
                 summaryKey: "nombre"),
        Question(id: .tone,
                 prompt: "¿Con qué tono te hablo?",
                 chips: ["Cercano y directo", "Cálido y tranquilo", "Sobrio y preciso"],
                 summaryKey: "tono"),
        Question(id: .askFirst,
                 prompt: "Cuando pueda actuar en el mundo — crear un evento, un recordatorio — ¿pregunto primero?",
                 chips: ["Pregunta antes de actuar", "Actúa y me cuentas"],
                 summaryKey: "actuar"),
    ]

    /// Defaults si el dueño salta el resto (continuos con Birth.seed).
    public static let defaults: [StepID: String] = [
        .name: Birth.seed.name,
        .tone: Birth.seed.tone,
        .askFirst: "Pregunta antes de actuar",
    ]

    public private(set) var answers: [StepID: String] = [:]

    public init() {}

    /// La siguiente pregunta sin responder; nil cuando terminó.
    public var currentQuestion: Question? {
        Self.questions.first { answers[$0.id] == nil }
    }

    public var isComplete: Bool { currentQuestion == nil }

    /// Responde la pregunta actual (chip o texto libre). Ignora vacíos.
    public mutating func answer(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let question = currentQuestion else { return }
        answers[question.id] = trimmed
    }

    /// "Saltar el resto": completa lo pendiente con los defaults del seed.
    public mutating func skipRemaining() {
        for step in StepID.allCases where answers[step] == nil {
            answers[step] = Self.defaults[step]
        }
    }

    /// Resumen key · value para la summary card (en el orden de las preguntas).
    public var summary: [(key: String, value: String)] {
        Self.questions.compactMap { question in
            answers[question.id].map { (question.summaryKey, $0) }
        }
    }

    /// La semilla del SelfModel. Requiere entrevista completa (o skipRemaining).
    public func birth(language: String = "español (es-CO)") -> Birth {
        let name = answers[.name] ?? Birth.seed.name
        let tone = answers[.tone] ?? Birth.seed.tone
        let askFirst = answers[.askFirst] ?? Self.defaults[.askFirst] ?? ""
        return Birth(name: name, tone: tone, language: language,
                     values: ["Antes de actuar en el mundo: \(askFirst.lowercased())"])
    }
}

// MARK: - Siembra del SelfModel al terminar el Birth

extension SelfModel {
    /// Siembra (o re-siembra en "Repetir onboarding" confirmado) la identidad
    /// desde el Birth, por el protected path: ciclos 0 → régimen bootstrap →
    /// apply() directo de identity/style/values con origin .bootstrap.
    public func seed(from birth: Birth) {
        setCycles(0)
        let view = birth.seedView
        apply(SelfProposal(field: .identity, value: view.identity,
                           rationale: "nacimiento (Birth)", origin: .bootstrap))
        apply(SelfProposal(field: .style, value: view.style,
                           rationale: "nacimiento (Birth)", origin: .bootstrap))
        if !view.values.isEmpty {
            apply(SelfProposal(field: .values, value: view.values.joined(separator: "\n"),
                               rationale: "nacimiento (Birth)", origin: .bootstrap))
        }
    }
}
