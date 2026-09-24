// AccountState.swift — identidad del dueño (Sign in with Apple vía Firebase
// Auth). Es SOLO registro de identidad: el acceso al modelo sigue siendo el
// token propio en Keychain. Perfil edge: la cuenta jamás bloquea el uso.

import Foundation

public enum AccountState: Sendable, Equatable {
    case signedOut
    case signedIn(uid: String, displayName: String?, email: String?)
    /// Sin proveedor de identidad (Firebase no configurado / no disponible).
    case unavailable

    public var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }
}

public enum AccountError: Error, Sendable, Equatable {
    /// Borrar exige sesión reciente: re-autenticar con Apple y reintentar.
    case requiresRecentLogin
    case cancelled
    case network
    case invalidCredential
    case failed(String)
}

/// Contrato de identidad; la impl real (FirebaseAuth) vive en el shell y el
/// mock en `PreviewAccountProvider`. La persistencia de sesión es del proveedor.
@MainActor
public protocol AccountProviding: AnyObject {
    func currentState() -> AccountState
    func signIn(with credential: AppleCredential) async throws -> AccountState
    func signOut() throws
    /// Borra SOLO la cuenta del proveedor (la mente local queda intacta).
    func deleteAccount() async throws
    /// Tras `requiresRecentLogin`: re-autentica con Apple, revoca el token de
    /// Apple si hay authorizationCode y borra la cuenta.
    func reauthenticateAndDelete(with credential: AppleCredential) async throws
}

/// Proveedor en memoria para tests y previews. Fallos inyectables.
@MainActor
public final class PreviewAccountProvider: AccountProviding {
    public var state: AccountState
    public var signInError: AccountError?
    public var deleteError: AccountError?
    public private(set) var reauthenticated = false
    public private(set) var revokedWithCode: String?

    public init(state: AccountState = .signedOut) {
        self.state = state
    }

    public func currentState() -> AccountState { state }

    public func signIn(with credential: AppleCredential) async throws -> AccountState {
        if let signInError { throw signInError }
        guard !credential.idToken.isEmpty else { throw AccountError.invalidCredential }
        state = .signedIn(uid: "preview-uid", displayName: nil, email: nil)
        return state
    }

    public func signOut() throws {
        state = .signedOut
    }

    public func deleteAccount() async throws {
        if let deleteError { throw deleteError }
        state = .signedOut
    }

    public func reauthenticateAndDelete(with credential: AppleCredential) async throws {
        reauthenticated = true
        revokedWithCode = credential.authorizationCode
        deleteError = nil
        state = .signedOut
    }
}
