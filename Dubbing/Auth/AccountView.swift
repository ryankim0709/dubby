import SwiftUI

/// The account sheet: signed-out prompt, Sign in with Apple, signed-in state, and failures with a retry.
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
                signedOutPrompt
            case .restoring:
                progress("Checking your account")
            case .signingIn:
                progress("Signing you in")
            case .signedIn(let profile):
                signedIn(profile)
            case .failed(let failure):
                failed(failure)
            }
        }
    }

    private var signedOutPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            EmptyStateView(
                systemImage: "person.crop.circle",
                title: "Sign in to use coaching",
                message: "Sign in with Apple so your coach can follow your practice across sessions."
            )
            .accessibilityIdentifier("accountSignedOut")
            appleButton
        }
    }

    private var appleButton: some View {
        Button {
            Task { await account.signIn() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "apple.logo")
                Text("Sign in with Apple")
            }
            .dubFont(17, weight: .semibold)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Sign in with Apple")
        .accessibilityIdentifier("signInWithApple")
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
        case .signIn: "Couldn't sign you in"
        case .registration: "Couldn't set up your account"
        case .signOut: "Couldn't sign you out"
        }
    }
}
