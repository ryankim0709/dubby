import AuthenticationServices
import ClerkConvex
import ClerkKit
import ConvexMobile
import Foundation

/// Signs in with Apple through Clerk and hands Clerk's session token to the shared Convex client.
final class ClerkAccountService: AccountService {
    private struct EnsureResult: Decodable {
        let userId: String
        let created: Bool
    }

    /// The Convex client is only ever driven from the main actor by this service and by the Clerk bridge.
    nonisolated(unsafe) private let client: ConvexClientWithAuth<String>

    private let loadTimeout: Duration = .seconds(10)

    init(configuration: AuthConfiguration) {
        Clerk.configure(publishableKey: configuration.clerkPublishableKey)
        client = ConvexClientWithAuth(deploymentUrl: configuration.convexURL.absoluteString, authProvider: ClerkConvexAuthProvider())
    }

    var convexClient: ConvexClientWithAuth<String> { client }

    func restoreSession() async throws -> AccountProfile? {
        try await waitForClerk()
        guard Clerk.shared.session?.status == .active else { return nil }
        try await connectConvex()
        return profile()
    }

    func signInWithApple() async throws -> AccountProfile {
        try await waitForClerk()
        do {
            try await Clerk.shared.auth.signInWithApple()
        } catch let error as ASAuthorizationError where error.code == .canceled {
            throw AccountError.cancelled
        }
        guard Clerk.shared.session?.status == .active else { throw AccountError.additionalStepsRequired }
        try await connectConvex()
        return profile()
    }

    func registerUser() async throws {
        do {
            let _: EnsureResult = try await client.mutation("users:ensure")
        } catch {
            throw AccountError.backend("Couldn't set up your account: \(error.localizedDescription)")
        }
    }

    func signOut() async throws {
        await client.logout()
        guard Clerk.shared.session == nil else { throw AccountError.signOutIncomplete }
    }

    func authToken() async throws -> String? {
        try await Clerk.shared.auth.getToken()
    }

    func sessionEnds() -> AsyncStream<Void> {
        let events = Clerk.shared.auth.events
        return AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    switch event {
                    case .signedOut, .accountDeleted:
                        continuation.yield()
                    case .sessionChanged(_, let newValue) where newValue == nil:
                        continuation.yield()
                    default:
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func waitForClerk() async throws {
        let deadline = ContinuousClock.now + loadTimeout
        while !Clerk.shared.isLoaded {
            guard ContinuousClock.now < deadline else { throw AccountError.accountTimedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func connectConvex() async throws {
        if case .failure(let error) = await client.loginFromCache() {
            throw AccountError.backend("Couldn't connect your account: \(error.localizedDescription)")
        }
    }

    private func profile() -> AccountProfile {
        let user = Clerk.shared.user
        let name = [user?.firstName, user?.lastName].compactMap { $0 }.joined(separator: " ")
        let fallback = user?.primaryEmailAddress?.emailAddress ?? "Signed in"
        return AccountProfile(displayName: name.isEmpty ? fallback : name)
    }
}

extension AccountModel {
    /// The model for this build: a Clerk-backed account when the build settings are filled in, otherwise a signed-out app.
    static func live(in bundle: Bundle) -> AccountModel {
        guard let configuration = AuthConfiguration.configured(in: bundle) else { return AccountModel(service: nil) }
        let service = ClerkAccountService(configuration: configuration)
        return AccountModel(service: service, convexClient: service.convexClient)
    }
}
