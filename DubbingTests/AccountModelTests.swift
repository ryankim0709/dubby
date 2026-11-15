import Foundation
import Testing
@testable import Dubbing

@MainActor
struct AccountModelTests {
    private final class FakeAccountService: AccountService {
        var restored: AccountProfile?
        var signInResult: Result<AccountProfile, AccountError> = .success(AccountProfile(displayName: "Sam"))
        var registerFailures = 0
        var registerCalls = 0
        var signOutFails = false
        var token: String? = "convex.jwt"
        var ends: [Void] = []

        func restoreSession() async throws -> AccountProfile? { restored }
        func signInWithApple() async throws -> AccountProfile { try signInResult.get() }
        func registerUser() async throws {
            registerCalls += 1
            if registerFailures > 0 {
                registerFailures -= 1
                throw AccountError.backend("offline")
            }
        }
        func signOut() async throws {
            if signOutFails { throw AccountError.signOutIncomplete }
            token = nil
        }
        func authToken() async throws -> String? { token }
        func sessionEnds() -> AsyncStream<Void> {
            let ends = ends
            return AsyncStream { continuation in
                ends.forEach { continuation.yield($0) }
                continuation.finish()
            }
        }
    }

    @Test func emptyConfigurationMeansSignedOut() async throws {
        #expect(AuthConfiguration(clerkPublishableKey: "", convexURL: "https://example.convex.cloud") == nil)
        #expect(AuthConfiguration(clerkPublishableKey: "pk_test_abc", convexURL: "") == nil)
        #expect(AuthConfiguration(clerkPublishableKey: "$(CLERK_PUBLISHABLE_KEY)", convexURL: "https://example.convex.cloud") == nil)
        #expect(AuthConfiguration(clerkPublishableKey: "pk_test_abc", convexURL: "https://example.convex.cloud") != nil)

        let account = AccountModel(service: nil)
        await account.start()
        await account.signIn()
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

        await account.signIn()
        #expect(account.phase == .signedIn(AccountProfile(displayName: "Sam")))
        #expect(service.registerCalls == 1)
        #expect(try await AccountTokenProvider(account: account).convexAuthToken() == "convex.jwt")
    }

    @Test func signOutClearsTheToken() async throws {
        let service = FakeAccountService()
        let account = AccountModel(service: service)
        await account.signIn()

        await account.signOut()
        #expect(account.phase == .signedOut)
        #expect(try await AccountTokenProvider(account: account).convexAuthToken() == nil)
    }

    @Test func failedSignOutIsReportedNotHidden() async throws {
        let service = FakeAccountService()
        service.signOutFails = true
        let account = AccountModel(service: service)
        await account.signIn()

        await account.signOut()
        #expect(account.phase == .failed(.init(step: .signOut, message: AccountError.signOutIncomplete.localizedDescription)))
        #expect(try await AccountTokenProvider(account: account).convexAuthToken() == nil)
    }

    @Test func storedSessionRestoresAndEndedSessionSignsOut() async throws {
        let service = FakeAccountService()
        service.restored = AccountProfile(displayName: "Sam")
        service.ends = [()]
        let account = AccountModel(service: service)

        await account.start()
        #expect(service.registerCalls == 1)
        #expect(account.phase == .signedOut)
    }

    @Test func cancelledAppleSheetIsNotAnError() async {
        let service = FakeAccountService()
        service.signInResult = .failure(.cancelled)
        let account = AccountModel(service: service)

        await account.signIn()
        #expect(account.phase == .signedOut)
    }

    @Test func registrationFailureIsNotSignedInUntilRetrySucceeds() async throws {
        let service = FakeAccountService()
        service.registerFailures = 1
        let account = AccountModel(service: service)

        await account.signIn()
        #expect(account.phase == .failed(.init(step: .registration, message: "offline")))
        #expect(try await AccountTokenProvider(account: account).convexAuthToken() == nil)

        await account.retry()
        #expect(account.phase == .signedIn(AccountProfile(displayName: "Sam")))
        #expect(try await AccountTokenProvider(account: account).convexAuthToken() == "convex.jwt")
    }
}
