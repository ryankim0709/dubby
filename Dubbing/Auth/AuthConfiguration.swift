import Foundation

/// The non-secret Clerk and Convex settings the build writes into Info.plist. A build that leaves
/// either one empty has no account, and the app runs signed out.
nonisolated struct AuthConfiguration: Equatable, Sendable {
    let clerkPublishableKey: String
    let convexURL: URL

    /// Returns nil unless both values are usable. Clerk asserts on a malformed key, so a value that
    /// isn't a Clerk publishable key (including an unexpanded build setting) must never reach it.
    init?(clerkPublishableKey: String?, convexURL: String?) {
        let key = clerkPublishableKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let urlText = convexURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard
            key.hasPrefix("pk_test_") || key.hasPrefix("pk_live_"),
            let url = URL(string: urlText),
            url.scheme == "https" || url.scheme == "http",
            url.host() != nil
        else { return nil }
        self.clerkPublishableKey = key
        self.convexURL = url
    }

    /// Reads the CLERK_PUBLISHABLE_KEY and CONVEX_URL build settings that Info.plist carries.
    static func configured(in bundle: Bundle) -> AuthConfiguration? {
        AuthConfiguration(
            clerkPublishableKey: bundle.object(forInfoDictionaryKey: "ClerkPublishableKey") as? String,
            convexURL: bundle.object(forInfoDictionaryKey: "ConvexURL") as? String
        )
    }
}
