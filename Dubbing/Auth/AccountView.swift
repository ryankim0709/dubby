import SwiftUI

/// The account sheet opened from the tabs: the signed-in learner and signing out.
struct AccountView: View {
    let account: AccountModel
    let onClose: () -> Void

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
                AccountPanel(account: account)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .screenBackground()
        .preferredColorScheme(.dark)
    }
}

/// The full-screen page a signed-out learner sees instead of the tabs.
struct SignInView: View {
    let account: AccountModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("DUB\(Text("BY").foregroundStyle(Palette.textSecondary))")
                    .displayFont(44)
                    .foregroundStyle(Palette.accentText)
                    .accessibilityAddTraits(.isHeader)
                AccountPanel(account: account)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("signInPage")
    }
}

/// Every account state: the username and password form, progress, the signed-in learner, and failures with a retry.
private struct AccountPanel: View {
    private enum CredentialMode: Hashable { case signIn, createAccount }

    let account: AccountModel

    // Held here rather than in the form so typed values survive the busy and failed phases.
    @State private var mode: CredentialMode = .signIn
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        if !account.isAvailable {
            EmptyStateView(
                systemImage: "person.crop.circle.badge.exclamationmark",
                title: "Sign-in isn't set up in this build",
                message: "This build has no account service connected, so you're using Dubby signed out."
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
                title: "Welcome to Dubby",
                message: "Sign in or create an account to start dubbing."
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
            .buttonStyle(SecondaryButtonStyle())
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
            .buttonStyle(SecondaryButtonStyle())
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
