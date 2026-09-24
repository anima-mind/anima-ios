import Foundation
import Testing
@testable import AnimaKit

@Suite struct AppleSignInHelperTests {

    @Test func nonceHasRequestedLengthAndCharset() {
        let allowed = Set(AppleSignInHelper.nonceCharset)
        for length in [1, 32, 64] {
            let nonce = AppleSignInHelper.randomNonce(length: length)
            #expect(nonce.count == length)
            #expect(nonce.allSatisfy { allowed.contains($0) })
        }
        #expect(AppleSignInHelper.randomNonce().count == 32)
    }

    @Test func noncesAreUnique() {
        let nonces = Set((0..<200).map { _ in AppleSignInHelper.randomNonce() })
        #expect(nonces.count == 200)
    }

    @Test func sha256MatchesKnownVectors() {
        #expect(AppleSignInHelper.sha256("")
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(AppleSignInHelper.sha256("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func displayNameJoinsNonEmptyParts() {
        #expect(AppleSignInHelper.displayName(given: "Ana", family: "Ríos") == "Ana Ríos")
        #expect(AppleSignInHelper.displayName(given: " Ana ", family: nil) == "Ana")
        #expect(AppleSignInHelper.displayName(given: "", family: nil) == nil)
    }
}

@Suite struct AccountStateTests {

    private func makeProfile() throws -> (AccountProfileStore, UserDefaults, String) {
        let suite = "test.anima.account.\(UUID().uuidString)"
        let ud = try #require(UserDefaults(suiteName: suite))
        return (AccountProfileStore(defaults: ud), ud, suite)
    }

    private let credential = AppleCredential(idToken: "id.token", rawNonce: "raw",
                                             authorizationCode: "code-1",
                                             fullName: "Ana Ríos", email: "ana@privaterelay.appleid.com")

    @MainActor @Test func withoutProviderIsUnavailableAndNeverThrows() async {
        let model = AccountViewModel(provider: nil)
        #expect(model.state == .unavailable)
        #expect(model.isAvailable == false)
        await model.signIn(with: credential)
        #expect(model.state == .unavailable)
        #expect(model.notice == AccountViewModel.unavailableNotice)
    }

    @MainActor @Test func signInUsesFirstTimeNameAsFallback() async throws {
        let (profile, ud, suite) = try makeProfile()
        defer { ud.removePersistentDomain(forName: suite) }
        let provider = PreviewAccountProvider()
        let model = AccountViewModel(provider: provider, profile: profile)
        #expect(model.state == .signedOut)

        await model.signIn(with: credential)
        #expect(model.state == .signedIn(uid: "preview-uid", displayName: "Ana Ríos",
                                         email: "ana@privaterelay.appleid.com"))
        #expect(model.displayLine == "Ana Ríos")

        // Segunda sesión: Apple ya no entrega nombre; el fallback persiste.
        let again = AccountViewModel(provider: provider, profile: profile)
        #expect(again.displayLine == "Ana Ríos")
    }

    @MainActor @Test func signInFailureIsSoftAndStaysSignedOut() async throws {
        let (profile, ud, suite) = try makeProfile()
        defer { ud.removePersistentDomain(forName: suite) }
        let provider = PreviewAccountProvider()
        provider.signInError = .network
        let model = AccountViewModel(provider: provider, profile: profile)
        await model.signIn(with: credential)
        #expect(model.state == .signedOut)
        #expect(model.notice?.contains("Sin conexión") == true)
        #expect(model.isWorking == false)
    }

    @MainActor @Test func cancelledSignInShowsNoNotice() async throws {
        let (profile, ud, suite) = try makeProfile()
        defer { ud.removePersistentDomain(forName: suite) }
        let provider = PreviewAccountProvider()
        provider.signInError = .cancelled
        let model = AccountViewModel(provider: provider, profile: profile)
        await model.signIn(with: credential)
        #expect(model.notice == nil)
    }

    @MainActor @Test func signOutReturnsToSignedOut() async throws {
        let (profile, ud, suite) = try makeProfile()
        defer { ud.removePersistentDomain(forName: suite) }
        let provider = PreviewAccountProvider(state: .signedIn(uid: "u1", displayName: "Ana", email: nil))
        let model = AccountViewModel(provider: provider, profile: profile)
        #expect(model.state.isSignedIn)
        model.signOut()
        #expect(model.state == .signedOut)
        #expect(model.displayLine == "Sin cuenta")
    }

    @MainActor @Test func deletionRequiresTypedWord() async throws {
        let (profile, ud, suite) = try makeProfile()
        defer { ud.removePersistentDomain(forName: suite) }
        let provider = PreviewAccountProvider(state: .signedIn(uid: "u1", displayName: nil, email: nil))
        let model = AccountViewModel(provider: provider, profile: profile)

        model.deletionConfirmText = "borrar"
        #expect(model.canConfirmDeletion == false)
        await model.deleteAccount()
        #expect(model.state.isSignedIn)

        model.deletionConfirmText = "  Eliminar "
        #expect(model.canConfirmDeletion)
        await model.deleteAccount()
        #expect(model.state == .signedOut)
        #expect(model.notice?.contains("Tu mente sigue") == true)
    }

    @MainActor @Test func deletionReauthenticatesWhenLoginIsStale() async throws {
        let (profile, ud, suite) = try makeProfile()
        defer { ud.removePersistentDomain(forName: suite) }
        profile.remember(credential)
        let provider = PreviewAccountProvider(state: .signedIn(uid: "u1", displayName: nil, email: nil))
        provider.deleteError = .requiresRecentLogin
        let model = AccountViewModel(provider: provider, profile: profile)

        model.deletionConfirmText = "eliminar"
        await model.deleteAccount()
        #expect(model.needsReauthForDeletion)
        #expect(model.state.isSignedIn)

        await model.reauthenticateAndDelete(with: credential)
        #expect(provider.reauthenticated)
        #expect(provider.revokedWithCode == "code-1")
        #expect(model.needsReauthForDeletion == false)
        #expect(model.state == .signedOut)
        // Se borra el fallback de perfil: Apple lo re-entrega tras revocar.
        #expect(profile.displayName == nil)
    }

    @MainActor @Test func prepareNonceKeepsRawAndReturnsHash() {
        let model = AccountViewModel(provider: PreviewAccountProvider())
        let hash = model.prepareNonce()
        let raw = try? #require(model.pendingNonce)
        #expect(hash == AppleSignInHelper.sha256(raw ?? ""))
        #expect(hash.count == 64)
    }
}
