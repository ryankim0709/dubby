import Combine
import ConvexMobile
import SafariServices
import SwiftUI

nonisolated struct PremiumStatus: Decodable, Equatable, Sendable {
    let isPremium: Bool
    let expiresAt: Double?

    func allowsCoach(at date: Date) -> Bool {
        guard isPremium else { return false }
        guard let expiresAt else { return true }
        return expiresAt.isFinite && expiresAt > date.timeIntervalSince1970 * 1000
    }
}

nonisolated struct WhopCheckout: Decodable, Identifiable, Sendable {
    let url: URL
    var id: URL { url }
}

/// The subscription belongs to the signed-in Convex learner; the phone never stores an unlock flag.
struct CoachAccessView: View {
    let account: AccountModel
    let onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: LoadState<PremiumStatus> = .loading
    @State private var isPaywallPresented = false
    @State private var isAccountPresented = false
    @State private var refreshID = UUID()
    @State private var accessDate = Date.now

    private var expiresAt: Double? {
        guard case .loaded(let premium) = status else { return nil }
        return premium.expiresAt
    }

    private var hasAccess: Bool {
        guard account.phase.isSignedIn, case .loaded(let premium) = status else { return false }
        return premium.allowsCoach(at: accessDate)
    }

    private var subscriptionError: String? {
        guard case .failed(let message) = status else { return nil }
        return message
    }

    var body: some View {
        Group {
            if hasAccess {
                CoachView(practice: nil, tokens: AccountTokenProvider(account: account), onClose: onClose)
            } else {
                NavigationStack {
                    VStack(spacing: 20) {
                        if !account.isAvailable {
                            EmptyStateView(systemImage: "person.crop.circle.badge.exclamationmark", title: "Sign-in isn't set up in this build", message: "Connect this build to the Dubby backend to sign in and check your subscription.")
                        } else if !account.phase.isSignedIn {
                            EmptyStateView(systemImage: "person.crop.circle", title: "Sign in to meet your coach", message: "Your subscription follows your Dubby account.")
                            Button("Sign in") { isAccountPresented = true }
                                .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
                        } else {
                            subscriptionState
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .screenBackground()
                    .foregroundStyle(Palette.textPrimary)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) }
                    }
                }
            }
        }
        .sheet(isPresented: $isPaywallPresented, onDismiss: paywallDismissed) {
            PremiumPaywall(account: account, subscriptionError: subscriptionError, onRetrySubscription: { refreshID = UUID() }, onClose: onClose)
        }
        .sheet(isPresented: $isAccountPresented) {
            AccountView(account: account, onClose: { isAccountPresented = false })
        }
        .task(id: refreshID) { await watchSubscription() }
        .task(id: expiresAt) { await watchExpiry() }
        .onChange(of: account.phase.isSignedIn) { _, signedIn in
            if signedIn {
                isAccountPresented = false
                refreshID = UUID()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshID = UUID() }
        }
        .preferredColorScheme(.dark)
        .tint(Palette.accentText)
    }

    @ViewBuilder
    private var subscriptionState: some View {
        switch status {
        case .loading:
            ProgressView("Checking coach access…")
                .tint(Palette.accentText)
        case .loaded:
            Text("Talk to a coach with Dubby Premium.")
                .dubFont(18, weight: .semibold)
            Button("View upgrade") { isPaywallPresented = true }
                .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
        case .failed(let message):
            EmptyStateView(systemImage: "wifi.exclamationmark", title: "Couldn't check your subscription", message: message)
            Button("Try again") { refreshID = UUID() }
                .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
        }
    }

    private func paywallDismissed() {
        if !hasAccess { onClose() }
    }

    private func watchSubscription() async {
        guard account.phase.isSignedIn, let client = account.convexClient else {
            status = .failed("Sign in to check your Dubby subscription.")
            return
        }
        do {
            for try await premium in client.subscribe(to: "billing:status", yielding: PremiumStatus.self).values {
                accessDate = .now
                status = .loaded(premium)
                isPaywallPresented = !premium.allowsCoach(at: .now)
            }
        } catch is CancellationError {
            return
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func watchExpiry() async {
        guard let expiresAt else { return }
        let remaining = expiresAt / 1000 - Date.now.timeIntervalSince1970
        do {
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            accessDate = .now
            isPaywallPresented = !hasAccess
        } catch is CancellationError {
            return
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

private struct PremiumPaywall: View {
    let account: AccountModel
    let subscriptionError: String?
    let onRetrySubscription: () -> Void
    let onClose: () -> Void
    @State private var checkout: WhopCheckout?
    @State private var isStartingCheckout = false
    @State private var checkoutError: String?
    @State private var hasOpenedCheckout = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "person.wave.2")
                        .font(.system(.largeTitle))
                        .foregroundStyle(Palette.accentText)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your next conversation starts here.")
                            .dubFont(30, weight: .bold)
                        Text("Talk to your character coach in the language you're practising. Get spoken help with wording and grammar.")
                            .dubFont(17, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("$4.99 / month")
                            .dubFont(24, weight: .semibold)
                        Text("Renews every 30 days. Cancel through Whop. Dubbing scenes stays free.")
                            .dubFont(14, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    if hasOpenedCheckout {
                        Label("Once Whop confirms payment, your coach unlocks here automatically.", systemImage: "clock")
                            .dubFont(14, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                            .accessibilityIdentifier("premiumAwaitingPayment")
                    }
                    if let checkoutError {
                        Text(checkoutError)
                            .dubFont(14, weight: .regular)
                            .foregroundStyle(Palette.streak)
                            .accessibilityIdentifier("premiumCheckoutError")
                    }
                    if let subscriptionError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Couldn't check your subscription: \(subscriptionError)")
                                .dubFont(14, weight: .regular)
                                .foregroundStyle(Palette.streak)
                            Button("Check subscription again", action: onRetrySubscription)
                                .frame(minHeight: 44)
                        }
                    }
                    Button {
                        isStartingCheckout = true
                    } label: {
                        HStack(spacing: 8) {
                            if isStartingCheckout { ProgressView().tint(Palette.onAccent) }
                            Text(isStartingCheckout ? "Opening checkout…" : "Upgrade with Whop")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
                    .disabled(isStartingCheckout)
                    .accessibilityIdentifier("premiumUpgrade")
                    Text("Checkout opens securely in Whop. Use the same Whop account to manage or cancel your subscription.")
                        .dubFont(12, weight: .regular)
                        .foregroundStyle(Palette.placeholder)
                }
                .padding(24)
            }
            .screenBackground()
            .foregroundStyle(Palette.textPrimary)
            .navigationTitle("Dubby Premium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) }
            }
        }
        .tint(Palette.accentText)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(item: $checkout) { checkout in WhopSafariView(url: checkout.url) }
        .task(id: isStartingCheckout) {
            if isStartingCheckout { await startCheckout() }
        }
    }

    private func startCheckout() async {
        checkoutError = nil
        defer { isStartingCheckout = false }
        guard account.phase.isSignedIn else {
            checkoutError = "Sign in before upgrading."
            return
        }
        do {
            let backend = try CoachBackendClient.configured(in: .main, tokens: AccountTokenProvider(account: account))
            let result = try await backend.createCheckout()
            guard result.url.scheme == "https", ["whop.com", "sandbox.whop.com"].contains(result.url.host()) else {
                throw AccountError.backend("Whop returned an invalid checkout URL.")
            }
            checkout = result
            hasOpenedCheckout = true
        } catch is CancellationError {
            return
        } catch {
            checkoutError = "Couldn't open Whop checkout: \(error.localizedDescription)"
        }
    }
}

private struct WhopSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
