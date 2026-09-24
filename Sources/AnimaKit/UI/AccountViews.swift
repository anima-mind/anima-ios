// AccountViews.swift — UI de la cuenta (Sign in with Apple): el paso "Tu
// cuenta" del onboarding y el botón nativo compartido con Ajustes. La cuenta
// es opcional: "Ahora no" siempre está disponible y ninguna falla bloquea.

#if canImport(SwiftUI)
import SwiftUI
#if os(iOS)
import AuthenticationServices
#endif

// MARK: - Botón nativo de Apple

/// `SignInWithAppleButton` estilo .black (legible sobre el bg navy), h48,
/// radius 8 y hairline del sistema. Fuera de iOS no hay flujo de Apple.
struct AppleSignInControl: View {
    @ObservedObject var account: AccountViewModel
    let purpose: AccountViewModel.Purpose

    var body: some View {
        #if os(iOS)
        SignInWithAppleButton(purpose == .signIn ? .signIn : .continue,
                              onRequest: { account.configure($0, purpose: purpose) },
                              onCompletion: { account.handle($0, purpose: purpose) })
            .signInWithAppleButtonStyle(.black)
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
            .disabled(account.isWorking)
            .opacity(account.isWorking ? 0.5 : 1)
        #else
        Text("Sign in with Apple solo está disponible en iOS.")
            .font(Theme.Type_.meta)
            .foregroundStyle(Theme.Colors.textFaint)
        #endif
    }
}

/// Fila de estado con sesión iniciada: check accent + nombre (+ email).
struct AccountSignedInRow: View {
    let name: String
    let email: String?

    var body: some View {
        HStack(spacing: Theme.Space.cardPad) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.Colors.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Theme.Type_.body)
                    .foregroundStyle(Theme.Colors.text)
                if let email, email != name {
                    Text(email)
                        .font(Theme.Type_.meta)
                        .foregroundStyle(Theme.Colors.textFaint)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 48)
        .padding(.horizontal, Theme.Space.cardPad)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
    }
}

extension AccountViewModel {
    var signedInEmail: String? {
        if case .signedIn(_, _, let email) = state { return email }
        return nil
    }
}

// MARK: - Paso 2 · Tu cuenta

struct AccountStep: View {
    @ObservedObject var account: AccountViewModel
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Tu cuenta")
                .font(Theme.Type_.screenTitle)
                .foregroundStyle(Theme.Colors.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.screenInset)
                .padding(.top, Theme.Space.stack)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 44, weight: .ultraLight))
                        .foregroundStyle(Theme.Colors.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Space.sectionGap)
                    Text("Tu identidad para lo que viene: respaldo y planes compartidos. Tu mente vive en este teléfono; la cuenta no guarda tus memorias ni tu key.")
                        .font(Theme.Type_.body)
                        .foregroundStyle(Theme.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if account.state.isSignedIn {
                        AccountSignedInRow(name: account.displayLine, email: account.signedInEmail)
                    }
                    if let notice = account.notice {
                        Text(notice)
                            .font(Theme.Type_.meta)
                            .foregroundStyle(Theme.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Theme.Space.screenInset)
            }

            footer
                .padding(.horizontal, Theme.Space.screenInset)
                .padding(.bottom, Theme.Space.sectionGap)
        }
        .onAppear { account.refresh() }
    }

    @ViewBuilder
    private var footer: some View {
        if account.state.isSignedIn {
            PrimaryOutlineButton(title: "Siguiente", action: onNext)
        } else {
            VStack(spacing: 4) {
                if account.isAvailable {
                    AppleSignInControl(account: account, purpose: .signIn)
                } else {
                    Text(AccountViewModel.unavailableNotice)
                        .font(Theme.Type_.meta)
                        .foregroundStyle(Theme.Colors.textFaint)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, Theme.Space.stack)
                }
                Button("Ahora no", action: onSkip)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Colors.textMuted)
                    .frame(maxWidth: .infinity, minHeight: Theme.minHitTarget)
                    .buttonStyle(.plain)
            }
        }
    }
}
#endif
