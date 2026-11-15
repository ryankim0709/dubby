import ConvexMobile
import Foundation
import Observation

/// What the account surface can say about the signed-in learner.
nonisolated struct AccountProfile: Equatable, Sendable {
    let displayName: String
}

nonisolated enum AccountError: LocalizedError, Equatable, Sendable {
    case cancelled
    case accountTimedOut
    case additionalStepsRequired
    case signOutIncomplete
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Sign in was cancelled."
        case .accountTimedOut: "Sign-in didn't finish loading. Check your connection and try again."
        case .additionalStepsRequired: "This account needs another step before it can sign in. Try again."
        case .signOutIncomplete: "Couldn't finish signing out. Try again."
        case .backend(let message): message
        }
    }
}

/// The identity provider and the cloud account behind sign-in. The Clerk implementation is the only
/// production one; tests supply a fake so the state machine runs without the network.
protocol AccountService {
    /// The learner whose session is already stored on this device, or nil when nobody is signed in.
    /// Connects the cloud client to that session before returning.
    func restoreSession() async throws -> AccountProfile?
    /// Runs the native Sign in with Apple flow and connects the cloud client to the new session.
    func signInWithApple() async throws -> AccountProfile
    /// Registers the signed-in learner with the backend (idempotent on the server).
    func registerUser() async throws
    func signOut() async throws
    /// The current Convex auth token, or nil when there is no session.
    func authToken() async throws -> String?
    /// Yields each time the session ends outside this app's own sign-out button (revoked, expired).
    func sessionEnds() -> AsyncStream<Void>
}

/// App-wide account state. The UI and the coach read it; nothing shows a signed-in state until the
/// backend has registered the learner.
@Observable
final class AccountModel {
    enum Step: Equatable { case restore, signIn, registration, signOut }

    struct Failure: Equatable {
        let step: Step
        let message: String
    }

    enum Phase: Equatable {
        case signedOut
        case restoring
        case signingIn
        case signedIn(AccountProfile)
        case failed(Failure)

        var isSignedIn: Bool {
            if case .signedIn = self { return true }
            return false
        }
    }

    private(set) var phase: Phase = .signedOut

    /// False when the build has no Clerk or Convex configuration, so signing in isn't possible.
    var isAvailable: Bool { service != nil }

    /// The one Convex client the app shares; nil when the build has no configuration. Cloud wrappers
    /// call through it so every request carries the signed-in learner's token.
    let convexClient: ConvexClientWithAuth<String>?

    private let service: (any AccountService)?
    private var pendingProfile: AccountProfile?

    init(service: (any AccountService)?, convexClient: ConvexClientWithAuth<String>? = nil) {
        self.service = service
        self.convexClient = convexClient
    }

    /// Restores a stored session, then follows the session until the view that owns this task goes away.
    func start() async {
        guard let service, phase == .signedOut else { return }
        await restore(service)
        for await _ in service.sessionEnds() {
            if case .signedIn = phase { phase = .signedOut }
        }
    }

    func signIn() async {
        guard let service else { return }
        switch phase {
        case .signedOut, .failed: break
        default: return
        }
        phase = .signingIn
        do {
            let profile = try await service.signInWithApple()
            await register(profile, with: service)
        } catch AccountError.cancelled {
            phase = .signedOut
        } catch {
            phase = .failed(Failure(step: .signIn, message: error.localizedDescription))
        }
    }

    func signOut() async {
        guard let service else { return }
        do {
            try await service.signOut()
            pendingProfile = nil
            phase = .signedOut
        } catch {
            phase = .failed(Failure(step: .signOut, message: error.localizedDescription))
        }
    }

    /// Repeats the step that failed.
    func retry() async {
        guard let service, case .failed(let failure) = phase else { return }
        switch failure.step {
        case .restore:
            await restore(service)
        case .signIn:
            await signIn()
        case .registration:
            guard let pendingProfile else { return await signIn() }
            await register(pendingProfile, with: service)
        case .signOut:
            await signOut()
        }
    }

    /// The Convex auth token for the signed-in learner, or nil in every other state.
    func currentToken() async throws -> String? {
        guard let service, case .signedIn = phase else { return nil }
        return try await service.authToken()
    }

    private func restore(_ service: any AccountService) async {
        phase = .restoring
        do {
            guard let profile = try await service.restoreSession() else {
                phase = .signedOut
                return
            }
            await register(profile, with: service)
        } catch {
            phase = .failed(Failure(step: .restore, message: error.localizedDescription))
        }
    }

    private func register(_ profile: AccountProfile, with service: any AccountService) async {
        pendingProfile = profile
        phase = .signingIn
        do {
            try await service.registerUser()
            phase = .signedIn(profile)
        } catch {
            phase = .failed(Failure(step: .registration, message: error.localizedDescription))
        }
    }
}

/// Gives the coach the signed-in learner's Convex token, and nothing when signed out.
nonisolated struct AccountTokenProvider: CoachAuthTokenProvider {
    let account: AccountModel

    func convexAuthToken() async throws -> String? {
        try await account.currentToken()
    }
}
