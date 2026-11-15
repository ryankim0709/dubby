import Foundation

/// The Convex deployment URL the build writes into Info.plist. A build that leaves it empty has no
/// account, and the app runs signed out.
nonisolated struct AuthConfiguration: Equatable, Sendable {
    let convexURL: URL

    /// Returns nil unless the value is a usable URL, so an empty or unexpanded build setting means signed out.
    init?(convexURL: String?) {
        let urlText = convexURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard
            let url = URL(string: urlText),
            url.scheme == "https" || url.scheme == "http",
            url.host() != nil
        else { return nil }
        self.convexURL = url
    }

    /// Reads the CONVEX_URL build setting that Info.plist carries.
    static func configured(in bundle: Bundle) -> AuthConfiguration? {
        AuthConfiguration(convexURL: bundle.object(forInfoDictionaryKey: "ConvexURL") as? String)
    }
}
