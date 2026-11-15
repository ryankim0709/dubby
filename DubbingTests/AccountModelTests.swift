import Foundation
import Security
import Testing
@testable import Dubbing

@MainActor
struct AccountModelTests {
    private final class FakeAccountService: AccountService {
        var restored: AccountProfile?
        var passwordResult: Result<AccountProfile, AccountError> = .success(AccountProfile(displayName: "sam"))
        var signedUpUsernames: [String] = []
        var registerFailures = 0
        var registerCalls = 0
        var signOutFails = false
        var token: String? = "convex.jwt"

        func restoreSession() async throws -> AccountProfile? { restored }
        func signIn(with credentials: PasswordCredentials) async throws -> AccountProfile { try passwordResult.get() }
        func signUp(with credentials: PasswordCredentials) async throws -> AccountProfile {
            signedUpUsernames.append(credentials.username)
            return try passwordResult.get()
        }
        func registerUser() async throws {
            registerCalls += 1
            if registerFailures > 0 {
                registerFailures -= 1
                throw AccountError.backend("offline")
            }
        }
        func signOut() async throws {
            if signOutFails { throw AccountError.keychain(errSecInteractionNotAllowed) }
            token = nil
        }
        func authToken() async throws -> String? { token }
    }

    private let demo = PasswordCredentials(username: "demo", password: "demo")

    @Test func emptyConfigurationMeansSignedOut() async throws {
        #expect(AuthConfiguration(convexURL: "") == nil)
        #expect(AuthConfiguration(convexURL: "$(CONVEX_URL)") == nil)
        #expect(AuthConfiguration(convexURL: "https://example.convex.cloud") != nil)

        let account = AccountModel(service: nil)
        await account.start()
        await account.signIn(with: demo)
        #expect(!account.isAvailable)
        #expect(account.phase == .signedOut)
        #expect(try await AccountTokenProvider(account: account).convexAuthToken() == nil)
    }

    @Test func signInRegistersTheLearnerOnceAndSharesTheToken() async throws {
        let service = FakeAccountService()
        let account = AccountModel(service: service)

        await account.start()
        #expect(account.phase == .signedOut)
        #expect(try await AccountTokenProvider(account: account).convexAuthToken() == nil)

        await account.signIn(with: demo)
        #expect(account.phase == .signedIn(AccountProfile(displayName: "sam")))
        #expect(service.registerCalls == 1)
        #expect(try await AccountTokenProvider(account: account).convexAuthToken() == "convex.jwt")
    }

    @Test func signUpRegistersTheLearner() async throws {
        let service = FakeAccountService()
        let account = AccountModel(service: service)

        await account.signUp(with: PasswordCredentials(username: "sam", password: "correct horse"))
        #expect(service.signedUpUsernames == ["sam"])
        #expect(service.registerCalls == 1)
        #expect(account.phase == .signedIn(AccountProfile(displayName: "sam")))
    }

    @Test func rejectedPasswordShowsTheMessageAndAllowsAnotherAttempt() async throws {
        let service = FakeAccountService()
        service.passwordResult = .failure(.backend("Wrong username or password"))
        let account = AccountModel(service: service)

        await account.signIn(with: demo)
        #expect(account.phase == .failed(.init(step: .credentials, message: "Wrong username or password")))
        #expect(service.registerCalls == 0)
        #expect(try await AccountTokenProvider(account: account).convexAuthToken() == nil)

        service.passwordResult = .success(AccountProfile(displayName: "demo"))
        await account.signIn(with: demo)
        #expect(account.phase == .signedIn(AccountProfile(displayName: "demo")))
    }

    @Test func signOutClearsTheToken() async throws {
        let service = FakeAccountService()
        let account = AccountModel(service: service)
        await account.signIn(with: demo)

        await account.signOut()
        #expect(account.phase == .signedOut)
        #expect(try await AccountTokenProvider(account: account).convexAuthToken() == nil)
    }

    @Test func failedSignOutIsReportedNotHidden() async throws {
        let service = FakeAccountService()
        service.signOutFails = true
        let account = AccountModel(service: service)
        await account.signIn(with: demo)

        await account.signOut()
        #expect(account.phase == .failed(.init(step: .signOut, message: AccountError.keychain(errSecInteractionNotAllowed).localizedDescription)))
        #expect(try await AccountTokenProvider(account: account).convexAuthToken() == nil)
    }

    @Test func storedSessionRestores() async throws {
        let service = FakeAccountService()
        service.restored = AccountProfile(displayName: "demo")
        let account = AccountModel(service: service)

        await account.start()
        #expect(service.registerCalls == 1)
        #expect(account.phase == .signedIn(AccountProfile(displayName: "demo")))
    }

    @Test func registrationFailureIsNotSignedInUntilRetrySucceeds() async throws {
        let service = FakeAccountService()
        service.registerFailures = 1
        let account = AccountModel(service: service)

        await account.signIn(with: demo)
        #expect(account.phase == .failed(.init(step: .registration, message: "offline")))
        #expect(try await AccountTokenProvider(account: account).convexAuthToken() == nil)

        await account.retry()
        #expect(account.phase == .signedIn(AccountProfile(displayName: "sam")))
        #expect(try await AccountTokenProvider(account: account).convexAuthToken() == "convex.jwt")
    }
}
