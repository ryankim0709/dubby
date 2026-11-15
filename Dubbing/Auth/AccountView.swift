import SwiftUI

/// The account sheet: username and password sign-in or sign-up, the signed-in state, and failures with a retry.
struct AccountView: View {
    private enum CredentialMode: Hashable { case signIn, createAccount }

    let account: AccountModel
    let onClose: () -> Void

    // Held here rather than in the form so typed values survive the busy and failed phases.
    @State private var mode: CredentialMode = .signIn
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Account")
                        .dubFont(24, weight: .semibold)
                        .foregroundStyle(Palette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .dubFont(16, weight: .medium)
                            .foregroundStyle(Palette.textPrimary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("accountClose")
                }
                content
                Text("Dubbing, exporting, My Dubs, and your local progress work without an account. Your coach needs one to see your practice.")
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Palette.background)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        if !account.isAvailable {
            EmptyStateView(
                systemImage: "person.crop.circle.badge.exclamationmark",
                title: "Sign-in isn't set up in this build",
                message: "This build has no account service connected, so you're using DubIt signed out."
            )
            .accessibilityIdentifier("accountUnavailable")
        } else {
            switch account.phase {
            case .signedOut:
                signedOutPrompt(errorMessage: nil)
            case .restoring:
                progress("Checking your account")
            case .signingIn:
                progress("Signing you in")
            case .signedIn(let profile):
                signedIn(profile)
            case .failed(let failure) where failure.step == .credentials:
                signedOutPrompt(errorMessage: failure.message)
            case .failed(let failure):
                failed(failure)
            }
        }
    }

    private func signedOutPrompt(errorMessage: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            EmptyStateView(
                systemImage: "person.crop.circle",
                title: "Sign in to use coaching",
                message: "Sign in so your coach can follow your practice across sessions."
            )
            .accessibilityIdentifier("accountSignedOut")
            credentialsForm(errorMessage: errorMessage)
        }
    }

    private var credentials: PasswordCredentials {
        PasswordCredentials(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
    }

    private var canSubmitCredentials: Bool {
        !credentials.username.isEmpty && !credentials.password.isEmpty
    }

    private func credentialsForm(errorMessage: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Account", selection: $mode) {
                Text("Sign in").tag(CredentialMode.signIn)
                Text("Create account").tag(CredentialMode.createAccount)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("credentialMode")

            TextField("Username", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .modifier(CredentialFieldStyle())
                .accessibilityIdentifier("usernameField")

            SecureField("Password", text: $password)
                .textContentType(mode == .createAccount ? .newPassword : .password)
                .submitLabel(.go)
                .onSubmit(submitCredentials)
                .modifier(CredentialFieldStyle())
                .accessibilityIdentifier("passwordField")

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityIdentifier("credentialsError")
            }

            Button(mode == .createAccount ? "Create account" : "Sign in", action: submitCredentials)
                .buttonStyle(PrimaryButtonStyle(cornerRadius: 12))
                .disabled(!canSubmitCredentials)
                .opacity(canSubmitCredentials ? 1 : 0.5)
                .accessibilityIdentifier("submitCredentials")
        }
    }

    private func submitCredentials() {
        guard canSubmitCredentials else { return }
        let credentials = credentials
        Task {
            switch mode {
            case .signIn: await account.signIn(with: credentials)
            case .createAccount: await account.signUp(with: credentials)
            }
            // A failed attempt keeps the password so a typo can be fixed; a session doesn't need it.
            if account.phase.isSignedIn { password = "" }
        }
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(Palette.accentText)
            Text(label)
                .dubFont(16, weight: .regular)
                .foregroundStyle(Palette.textPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("accountBusy")
    }

    private func signedIn(_ profile: AccountProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Signed in")
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
                Text(profile.displayName)
                    .dubFont(18, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("accountSignedIn")
            Button("Sign out") {
                Task { await account.signOut() }
            }
            .buttonStyle(OutlineCapsuleButtonStyle())
            .accessibilityIdentifier("signOut")
        }
    }

    private func failed(_ failure: AccountModel.Failure) -> some View {
        VStack(spacing: 12) {
            EmptyStateView(systemImage: "exclamationmark.triangle", title: title(for: failure.step), message: failure.message)
                .accessibilityIdentifier("accountFailed")
            Button("Try again") {
                Task { await account.retry() }
            }
            .buttonStyle(OutlineCapsuleButtonStyle())
            .accessibilityIdentifier("accountRetry")
        }
    }

    private func title(for step: AccountModel.Step) -> String {
        switch step {
        case .restore: "Couldn't check your account"
        case .credentials: "Couldn't sign you in"
        case .registration: "Couldn't set up your account"
        case .signOut: "Couldn't sign you out"
        }
    }
}

private struct CredentialFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .dubFont(17, weight: .regular)
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
