// AccountViewModel.swift — estado de la cuenta compartido por el onboarding
// (paso "Tu cuenta") y Ajustes (sección Cuenta). Toda falla es suave: se
// muestra un aviso y la app sigue; la cuenta jamás bloquea (perfil edge).

import Foundation
import Combine
#if os(iOS)
import AuthenticationServices
#endif

@MainActor
public final class AccountViewModel: ObservableObject {

    public enum Purpose: Sendable {
        case signIn
        case confirmDeletion
    }

    /// Palabra que el dueño tipea para eliminar la cuenta (fricción donde importa).
    public static let deletionWord = "eliminar"

    @Published public private(set) var state: AccountState
    @Published public private(set) var isWorking = false
    /// Aviso suave (fallo de red, cuenta eliminada…). Nunca bloquea.
    @Published public var notice: String?
    /// `user.delete()` pidió sesión reciente: hay que confirmar con Apple.
    @Published public private(set) var needsReauthForDeletion = false
    @Published public var deletionConfirmText = ""

    private let provider: (any AccountProviding)?
    private let profile: AccountProfileStore
    /// Nonce crudo de la autorización en curso (su SHA256 va a Apple).
    private(set) var pendingNonce: String?

    public init(provider: (any AccountProviding)?,
                profile: AccountProfileStore = AccountProfileStore()) {
        self.provider = provider
        self.profile = profile
        self.state = .unavailable
        refresh()
    }

    public var isAvailable: Bool { provider != nil && state != .unavailable }

    /// Línea visible del estado: nombre, email o un genérico.
    public var displayLine: String {
        switch state {
        case .signedIn(_, let name, let email): return name ?? email ?? "Cuenta de Apple"
        case .signedOut: return "Sin cuenta"
        case .unavailable: return "No disponible"
        }
    }

    public func refresh() {
        state = resolved(provider?.currentState() ?? .unavailable)
    }

    // MARK: Sign in

    /// Genera y retiene el nonce crudo; devuelve el SHA256 para el request.
    @discardableResult
    public func prepareNonce() -> String {
        let nonce = AppleSignInHelper.randomNonce()
        pendingNonce = nonce
        return AppleSignInHelper.sha256(nonce)
    }

    public func signIn(with credential: AppleCredential) async {
        guard let provider else {
            notice = Self.unavailableNotice
            return
        }
        profile.remember(credential)
        isWorking = true
        defer { isWorking = false }
        do {
            state = resolved(try await provider.signIn(with: credential))
            notice = nil
        } catch {
            state = resolved(provider.currentState())
            notice = Self.notice(for: error)
        }
    }

    public func signOut() {
        guard let provider else { return }
        do {
            try provider.signOut()
            notice = nil
        } catch {
            notice = Self.notice(for: error)
        }
        refresh()
    }

    // MARK: Eliminar cuenta (App Store 5.1.1(v))

    public var canConfirmDeletion: Bool {
        deletionConfirmText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Self.deletionWord
    }

    public func deleteAccount() async {
        guard canConfirmDeletion, let provider else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await provider.deleteAccount()
            finishDeletion()
        } catch AccountError.requiresRecentLogin {
            needsReauthForDeletion = true
            notice = "Por seguridad, confirma con Apple para eliminar la cuenta."
        } catch {
            notice = Self.notice(for: error)
        }
    }

    public func reauthenticateAndDelete(with credential: AppleCredential) async {
        guard let provider else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await provider.reauthenticateAndDelete(with: credential)
            finishDeletion()
        } catch {
            notice = Self.notice(for: error)
        }
    }

    public func cancelDeletion() {
        deletionConfirmText = ""
        needsReauthForDeletion = false
        pendingNonce = nil
    }

    private func finishDeletion() {
        profile.clear()
        deletionConfirmText = ""
        needsReauthForDeletion = false
        refresh()
        notice = "Cuenta eliminada. Tu mente sigue en este teléfono."
    }

    // MARK: Apple (AuthenticationServices)

    #if os(iOS)
    public func configure(_ request: ASAuthorizationAppleIDRequest, purpose: Purpose) {
        request.requestedScopes = purpose == .signIn ? [.fullName, .email] : []
        request.nonce = prepareNonce()
    }

    public func handle(_ result: Result<ASAuthorization, Error>, purpose: Purpose) {
        switch result {
        case .failure(let error):
            pendingNonce = nil
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            notice = Self.notice(for: error)
        case .success(let authorization):
            guard let nonce = pendingNonce,
                  let credential = AppleCredential(authorization: authorization, rawNonce: nonce) else {
                notice = Self.notice(for: AccountError.invalidCredential)
                return
            }
            pendingNonce = nil
            Task {
                switch purpose {
                case .signIn: await signIn(with: credential)
                case .confirmDeletion: await reauthenticateAndDelete(with: credential)
                }
            }
        }
    }
    #endif

    // MARK: Helpers

    /// Completa nombre/email con el fallback capturado la primera vez.
    private func resolved(_ state: AccountState) -> AccountState {
        guard case .signedIn(let uid, let name, let email) = state else { return state }
        return .signedIn(uid: uid,
                         displayName: name ?? profile.displayName,
                         email: email ?? profile.email)
    }

    static let unavailableNotice = "Las cuentas no están disponibles ahora. Anima funciona igual sin una."

    static func notice(for error: Error) -> String? {
        switch error as? AccountError {
        case .cancelled?:
            return nil
        case .network?:
            return "Sin conexión con el servicio de cuentas. Puedes seguir y entrar luego desde Ajustes."
        case .invalidCredential?:
            return "Apple no entregó una credencial válida. Intenta de nuevo o sigue sin cuenta."
        default:
            return "No se pudo completar ahora. Anima funciona igual sin cuenta."
        }
    }
}
