// AppleSignInHelper.swift — nonce de Sign in with Apple para Firebase Auth.
// Apple firma el SHA256 del nonce dentro del idToken; Firebase recibe el nonce
// crudo y verifica que coincidan (anti-replay). Lógica pura, testeable.

import Foundation
import CryptoKit
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

public enum AppleSignInHelper {
    public static let nonceCharset: [Character] =
        Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")

    /// Nonce aleatorio con CSPRNG del sistema (SystemRandomNumberGenerator).
    public static func randomNonce(length: Int = 32) -> String {
        precondition(length > 0)
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in nonceCharset.randomElement(using: &generator)! })
    }

    /// SHA256 hex en minúsculas: lo que va en `ASAuthorizationAppleIDRequest.nonce`.
    public static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Nombre legible desde los componentes que Apple entrega solo la primera vez.
    public static func displayName(given: String?, family: String?) -> String? {
        let parts = [given, family]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Lo que el shell necesita de la autorización de Apple, sin tipos de
/// AuthenticationServices (Sendable, testeable).
public struct AppleCredential: Sendable, Equatable {
    public let idToken: String
    public let rawNonce: String
    public let authorizationCode: String?
    /// Solo llegan en la PRIMERA autorización del Apple ID con esta app.
    public let fullName: String?
    public let email: String?

    public init(idToken: String, rawNonce: String, authorizationCode: String? = nil,
                fullName: String? = nil, email: String? = nil) {
        self.idToken = idToken
        self.rawNonce = rawNonce
        self.authorizationCode = authorizationCode
        self.fullName = fullName
        self.email = email
    }
}

#if os(iOS)
extension AppleCredential {
    /// Extrae la credencial del ASAuthorization; nil si falta el identityToken.
    public init?(authorization: ASAuthorization, rawNonce: String) {
        guard let apple = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = apple.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else { return nil }
        let code = apple.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        self.init(idToken: idToken,
                  rawNonce: rawNonce,
                  authorizationCode: code,
                  fullName: AppleSignInHelper.displayName(given: apple.fullName?.givenName,
                                                          family: apple.fullName?.familyName),
                  email: apple.email)
    }
}
#endif

/// Fallback del displayName: Apple entrega nombre/email UNA vez; se guardan
/// aquí (no son secretos) para mostrarlos en sesiones siguientes.
public struct AccountProfileStore: @unchecked Sendable {
    public static let displayNameKey = "anima.account.displayName"
    public static let emailKey = "anima.account.email"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var displayName: String? { defaults.string(forKey: Self.displayNameKey) }
    public var email: String? { defaults.string(forKey: Self.emailKey) }

    /// Persiste solo lo que venga (nunca pisa con nil lo capturado antes).
    public func remember(_ credential: AppleCredential) {
        if let name = credential.fullName, !name.isEmpty {
            defaults.set(name, forKey: Self.displayNameKey)
        }
        if let email = credential.email, !email.isEmpty {
            defaults.set(email, forKey: Self.emailKey)
        }
    }

    public func clear() {
        defaults.removeObject(forKey: Self.displayNameKey)
        defaults.removeObject(forKey: Self.emailKey)
    }
}
