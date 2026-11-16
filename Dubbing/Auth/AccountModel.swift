import ConvexMobile
import Foundation
import Observation

/// What the account surface can say about the signed-in learner.
nonisolated struct AccountProfile: Equatable, Sendable {
    let displayName: String
}

/// A username and password as typed. Clerk enforces its own username and password rules and
/// returns a readable message when they aren't met, so the app only requires both to be non-empty.
nonisolated struct PasswordCredentials: Equatable, Sendable {
    let username: String
    let password: String
}

nonisolated enum AccountError: LocalizedError, Equatable, Sendable {
    case keychain(OSStatus)
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .keychain(let status): "Couldn't read or update the sign-in saved on this iPhone (Keychain status \(status))."
        case .backend(let message): message
        }
    }
}

/// The cloud account behind sign-in. PasswordAccountService is the only production implementation;
/// tests supply a fake so the state machine runs without the network.
protocol AccountService {
    /// The learner whose session is already stored on this device, or nil when nobody is signed in.
    /// Connects the cloud client to that session before returning.
    func restoreSession() async throws -> AccountProfile?
    /// Signs in to an existing account and connects the cloud client to the new session.
    func signIn(with credentials: PasswordCredentials) async throws -> AccountProfile
    /// Creates an account and connects the cloud client to its first session.
    func signUp(with credentials: PasswordCredentials) async throws -> AccountProfile
    /// Registers the signed-in learner with the backend (idempotent on the server).
    func registerUser() async throws
    func signOut() async throws
    /// The current Convex auth token, or nil when there is no session.
    func authToken() async throws -> String?
}

/// App-wide account state. The UI and the coach read it; nothing shows a signed-in state until the
/// backend has registered the learner.
@Observable
final class AccountModel {
    /// `credentials` is a failed username and password attempt; the form shows the message and the
    /// learner resubmits, because the password isn't kept for a retry.
    enum Step: Equatable { case restore, credentials, registration, signOut }

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

    /// False when the build has no Convex configuration, so signing in isn't possible.
    var isAvailable: Bool { service != nil }

    var username: String? {
        guard case .signedIn(let profile) = phase else { return nil }
        return profile.displayName
    }

    /// The one Convex client the app shares; nil when the build has no configuration. Cloud wrappers
    /// call through it so every request carries the signed-in learner's token.
    let convexClient: ConvexClientWithAuth<String>?

    private let service: (any AccountService)?
    private var pendingProfile: AccountProfile?

    init(service: (any AccountService)?, convexClient: ConvexClientWithAuth<String>? = nil) {
        self.service = service
        self.convexClient = convexClient
    }

    /// Restores the session saved on this device, if any.
    func start() async {
        guard let service, phase == .signedOut else { return }
        await restore(service)
    }

    func signIn(with credentials: PasswordCredentials) async {
        await authenticate { try await $0.signIn(with: credentials) }
    }

    func signUp(with credentials: PasswordCredentials) async {
        await authenticate { try await $0.signUp(with: credentials) }
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
        case .credentials:
            phase = .signedOut
        case .registration:
            guard let pendingProfile else {
                phase = .signedOut
                return
            }
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

    private func authenticate(_ operation: (any AccountService) async throws -> AccountProfile) async {
        guard let service else { return }
        switch phase {
        case .signedOut, .failed: break
        default: return
        }
        phase = .signingIn
        do {
            let profile = try await operation(service)
            await register(profile, with: service)
        } catch {
            phase = .failed(Failure(step: .credentials, message: error.localizedDescription))
        }
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
