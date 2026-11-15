import ConvexMobile
import Foundation
import Security

/// A signed-in username and its Convex session token, kept in the Keychain between launches.
nonisolated struct PasswordSession: Codable, Equatable, Sendable {
    let token: String
    let username: String
    /// Epoch milliseconds, matching the token's expiry.
    let expiresAt: Double

    func isExpired(at date: Date) -> Bool {
        date.timeIntervalSince1970 * 1000 >= expiresAt
    }
}

/// The one saved session. The Keychain rather than UserDefaults, because the token is a credential.
nonisolated struct SessionKeychain: Sendable {
    let service: String

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session"]
    }

    func load() throws -> PasswordSession? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw AccountError.keychain(status) }
        return try JSONDecoder().decode(PasswordSession.self, from: data)
    }

    func save(_ session: PasswordSession) throws {
        try delete()
        var item = query
        item[kSecValueData as String] = try JSONEncoder().encode(session)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw AccountError.keychain(status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountError.keychain(status) }
    }
}

/// Hands the saved session token to the Convex client. The service saves and deletes the session itself.
nonisolated final class SavedSessionAuthProvider: AuthProvider {
    private let keychain: SessionKeychain

    init(keychain: SessionKeychain) {
        self.keychain = keychain
    }

    func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
        try savedToken()
    }

    func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
        try savedToken()
    }

    func logout() async throws {}

    func extractIdToken(from authResult: String) -> String {
        authResult
    }

    private func savedToken() throws -> String {
        guard let session = try keychain.load() else { throw AccountError.backend("There's no saved sign-in on this iPhone.") }
        return session.token
    }
}

/// Signs in with a username and password through the backend's passwordAuth actions and hands the
/// session token to the shared Convex client.
final class PasswordAccountService: AccountService {
    private struct EnsureResult: Decodable {
        let userId: String
        let created: Bool
    }

    private struct BackendErrorData: Decodable {
        let message: String
    }

    /// The Convex client is only ever driven from the main actor by this service and the cloud wrappers.
    nonisolated(unsafe) private let client: ConvexClientWithAuth<String>
    private let keychain: SessionKeychain

    init(configuration: AuthConfiguration, keychain: SessionKeychain) {
        self.keychain = keychain
        client = ConvexClientWithAuth(
            deploymentUrl: configuration.convexURL.absoluteString,
            authProvider: SavedSessionAuthProvider(keychain: keychain)
        )
    }

    var convexClient: ConvexClientWithAuth<String> { client }

    func restoreSession() async throws -> AccountProfile? {
        guard let session = try keychain.load() else { return nil }
        // The backend rejects an expired token on every call, so it counts as signed out.
        guard !session.isExpired(at: .now) else {
            try keychain.delete()
            return nil
        }
        return try await connect(session)
    }

    func signIn(with credentials: PasswordCredentials) async throws -> AccountProfile {
        let session = try await requestSession("passwordAuth:signIn", credentials)
        try keychain.save(session)
        return try await connect(session)
    }

    func signUp(with credentials: PasswordCredentials) async throws -> AccountProfile {
        let session = try await requestSession("passwordAuth:signUp", credentials)
        try keychain.save(session)
        return try await connect(session)
    }

    func registerUser() async throws {
        do {
            let _: EnsureResult = try await client.mutation("users:ensure")
        } catch {
            throw AccountError.backend("Couldn't set up your account: \(error.localizedDescription)")
        }
    }

    func signOut() async throws {
        try keychain.delete()
        await client.logout()
    }

    func authToken() async throws -> String? {
        try keychain.load()?.token
    }

    private func requestSession(_ actionName: String, _ credentials: PasswordCredentials) async throws -> PasswordSession {
        do {
            return try await client.action(actionName, with: ["username": credentials.username, "password": credentials.password])
        } catch ClientError.ConvexError(let data) {
            throw AccountError.backend(Self.message(fromErrorData: data))
        } catch {
            throw AccountError.backend("Couldn't reach DubIt: \(error.localizedDescription)")
        }
    }

    private func connect(_ session: PasswordSession) async throws -> AccountProfile {
        if case .failure(let error) = await client.loginFromCache() {
            throw AccountError.backend("Couldn't connect your account: \(error.localizedDescription)")
        }
        return AccountProfile(displayName: session.username)
    }

    /// Backend app errors carry `{ code, message }`; the message is written for people.
    private static func message(fromErrorData data: String) -> String {
        guard let decoded = try? JSONDecoder().decode(BackendErrorData.self, from: Data(data.utf8)) else { return data }
        return decoded.message
    }
}

extension AccountModel {
    /// The model for this build: password accounts when the build has a Convex URL, otherwise a signed-out app.
    static func live(in bundle: Bundle) -> AccountModel {
        guard let configuration = AuthConfiguration.configured(in: bundle) else { return AccountModel(service: nil) }
        let service = PasswordAccountService(configuration: configuration, keychain: SessionKeychain(service: "dubit.password-session"))
        return AccountModel(service: service, convexClient: service.convexClient)
    }
}
