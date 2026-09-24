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

// MARK: - Ajustes · Cuenta

/// Sección Cuenta de Ajustes: estado, iniciar/cerrar sesión y eliminar cuenta
/// (App Store 5.1.1(v)). Borrar la cuenta NO toca la mente local.
struct AccountSettingsSection: View {
    @ObservedObject var account: AccountViewModel
    @State private var showDeletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            Text("Cuenta")
                .font(Theme.Type_.label)
                .textCase(.uppercase)
                .kerning(0.66)
                .foregroundStyle(Theme.Colors.textMuted)

            switch account.state {
            case .signedIn:
                VStack(spacing: 0) {
                    statusRow
                    separator
                    actionRow("Cerrar sesión", color: Theme.Colors.accentText) { account.signOut() }
                    separator
                    actionRow("Eliminar cuenta", color: Theme.Colors.textMuted) {
                        account.cancelDeletion()
                        showDeletion = true
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
            case .signedOut:
                VStack(spacing: 0) {
                    statusRow
                }
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                AppleSignInControl(account: account, purpose: .signIn)
            case .unavailable:
                VStack(spacing: 0) {
                    statusRow
                }
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
            }

            if let notice = account.notice {
                Text(notice)
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textMuted)
            }
            Text("La cuenta es solo tu identidad; tu mente y tu key viven en este teléfono.")
                .font(Theme.Type_.meta)
                .foregroundStyle(Theme.Colors.textFaint)
        }
        .onAppear { account.refresh() }
        .sheet(isPresented: $showDeletion, onDismiss: { account.cancelDeletion() }) {
            AccountDeletionSheet(account: account) { showDeletion = false }
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(Theme.Radius.sheet)
                .presentationBackground(Theme.Colors.bg)
        }
    }

    private var statusRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayLine)
                    .font(Theme.Type_.body)
                    .foregroundStyle(account.state.isSignedIn ? Theme.Colors.text : Theme.Colors.textMuted)
                if let email = account.signedInEmail, email != account.displayLine {
                    Text(email)
                        .font(Theme.Type_.meta)
                        .foregroundStyle(Theme.Colors.textFaint)
                }
            }
            Spacer()
            if account.state.isSignedIn {
                Text("Apple")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.textMuted)
            }
        }
        .frame(minHeight: 48)
        .padding(.horizontal, Theme.Space.cardPad)
    }

    private var separator: some View {
        Divider().background(Theme.Colors.border).padding(.leading, Theme.Space.cardPad)
    }

    private func actionRow(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(Theme.Type_.body)
                    .foregroundStyle(color)
                Spacer()
            }
            .frame(height: 48)
            .padding(.horizontal, Theme.Space.cardPad)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(account.isWorking)
    }
}

/// Confirmación tipeando "eliminar" (fricción donde importa). Si Firebase pide
/// sesión reciente, se confirma con Apple y el borrado se completa solo.
struct AccountDeletionSheet: View {
    @ObservedObject var account: AccountViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
            Text("Eliminar cuenta")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.Colors.text)
            Text("Se borra tu cuenta de Anima (tu identidad con Apple). Tu mente —memorias, identidad y key— se queda intacta en este teléfono.")
                .font(Theme.Type_.body)
                .foregroundStyle(Theme.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Escribe \(AccountViewModel.deletionWord) para confirmar")
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textFaint)
                TextField(AccountViewModel.deletionWord, text: $account.deletionConfirmText)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Theme.Colors.text)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .padding(Theme.Space.cardPad)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .strokeBorder(account.canConfirmDeletion ? Theme.Colors.accent : Theme.Colors.border,
                                          lineWidth: Theme.Stroke.hairline))
            }

            if account.needsReauthForDeletion {
                AppleSignInControl(account: account, purpose: .confirmDeletion)
            }
            if let notice = account.notice {
                Text(notice)
                    .font(Theme.Type_.meta)
                    .foregroundStyle(Theme.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: Theme.Space.stack) {
                Button(action: onClose) {
                    Text("Cancelar")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.Colors.textMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
                }
                .buttonStyle(.plain)
                let enabled = account.canConfirmDeletion && !account.isWorking && !account.needsReauthForDeletion
                Button {
                    Task { await account.deleteAccount() }
                } label: {
                    Group {
                        if account.isWorking {
                            ProgressView().controlSize(.small).tint(Theme.Colors.accent)
                        } else {
                            Text("Eliminar cuenta")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(enabled ? Theme.Colors.accentText : Theme.Colors.textFaint)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .strokeBorder(enabled ? Theme.Colors.accent : Theme.Colors.border,
                                          lineWidth: Theme.Stroke.hairline))
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
            }
        }
        .padding(Theme.Space.screenInset)
        .onChange(of: account.state) { _, state in
            if !state.isSignedIn { onClose() }
        }
    }
}
#endif
