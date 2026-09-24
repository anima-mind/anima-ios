// FirebaseAccountProvider.swift — AccountProviding con FirebaseAuth (proveedor
// apple.com). Solo registro de identidad: no toca el token del provider ni el
// Keychain. La sesión la persiste FirebaseAuth. Se usan las variantes con
// completion (callback en main thread) para no cruzar tipos no-Sendable de
// Firebase entre aislamientos en Swift 6.

import Foundation
import AnimaKit
import FirebaseAuth

@MainActor
final class FirebaseAccountProvider: AccountProviding {

    func currentState() -> AccountState {
        guard let user = Auth.auth().currentUser else { return .signedOut }
        return .signedIn(uid: user.uid, displayName: user.displayName, email: user.email)
    }

    func signIn(with credential: AppleCredential) async throws -> AccountState {
        let firebaseCredential = Self.firebaseCredential(credential)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Auth.auth().signIn(with: firebaseCredential) { _, error in
                if let error { continuation.resume(throwing: Self.map(error)) } else { continuation.resume() }
            }
        }
        // Apple entrega el nombre solo la primera vez: se deja en el perfil de
        // Firebase (best-effort; el fallback local ya lo tiene).
        if let name = credential.fullName, let user = Auth.auth().currentUser, user.displayName == nil {
            let change = user.createProfileChangeRequest()
            change.displayName = name
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                change.commitChanges { _ in continuation.resume() }
            }
        }
        return currentState()
    }

    func signOut() throws {
        do {
            try Auth.auth().signOut()
        } catch {
            throw Self.map(error)
        }
    }

    func deleteAccount() async throws {
        guard let user = Auth.auth().currentUser else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            user.delete { error in
                if let error { continuation.resume(throwing: Self.map(error)) } else { continuation.resume() }
            }
        }
    }

    func reauthenticateAndDelete(with credential: AppleCredential) async throws {
        guard let user = Auth.auth().currentUser else { return }
        let firebaseCredential = Self.firebaseCredential(credential)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            user.reauthenticate(with: firebaseCredential) { _, error in
                if let error { continuation.resume(throwing: Self.map(error)) } else { continuation.resume() }
            }
        }
        // Revocar el token de Apple (requisito de Apple al borrar cuentas SIWA).
        // Best-effort: si falla, el borrado de la cuenta sigue.
        if let code = credential.authorizationCode {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Auth.auth().revokeToken(withAuthorizationCode: code) { _ in continuation.resume() }
            }
        }
        try await deleteAccount()
    }

    // MARK: Helpers

    private static func firebaseCredential(_ credential: AppleCredential) -> OAuthCredential {
        OAuthProvider.credential(providerID: .apple,
                                 idToken: credential.idToken,
                                 rawNonce: credential.rawNonce)
    }

    private static func map(_ error: Error) -> AccountError {
        let ns = error as NSError
        guard ns.domain == AuthErrors.domain, let code = AuthErrorCode(rawValue: ns.code) else {
            return .failed(ns.localizedDescription)
        }
        switch code {
        case .requiresRecentLogin, .userTokenExpired: return .requiresRecentLogin
        case .networkError: return .network
        case .invalidCredential, .missingOrInvalidNonce: return .invalidCredential
        case .webContextCancelled: return .cancelled
        default: return .failed(ns.localizedDescription)
        }
    }
}
