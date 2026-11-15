import Foundation
import os

/// JSON over HTTPS with bounded retries, shared by the coach's backend and LiveAvatar clients.
nonisolated enum ServiceRequest {
    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "coach-network")
    private static let maxAttempts = 3

    private enum Attempt {
        case succeeded(Data)
        case failed(CoachError, status: Int, retryable: Bool)
    }

    /// Sends the request, retrying network failures, 429, and 5xx with exponential backoff.
    /// Other statuses fail at once. A cancelled task cancels the request and throws `CancellationError`.
    static func data(for request: URLRequest, operation: String) async throws -> Data {
        for attempt in 1... {
            switch try await send(request, operation: operation) {
            case .succeeded(let data):
                return data
            case .failed(let error, let status, let retryable):
                guard retryable, attempt < maxAttempts else { throw error }
                // Only the operation and status are logged: bodies and headers can hold tokens.
                logger.warning("Coach request failed, retrying. operation=\(operation, privacy: .public) attempt=\(attempt) status=\(status)")
                try await Task.sleep(for: .milliseconds(250 * (1 << (attempt - 1))))
            }
        }
        preconditionFailure("The retry loop only ends by returning or throwing")
    }

    private static func send(_ request: URLRequest, operation: String) async throws -> Attempt {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            let failure: CoachError = CoachError.isOffline(error)
                ? .offline(operation: operation)
                : .requestFailed(operation: operation, status: 0, body: error.localizedDescription)
            return .failed(failure, status: 0, retryable: true)
        }
        guard let http = response as? HTTPURLResponse else {
            return .failed(.invalidResponse(operation: operation, reason: "the response wasn't HTTP"), status: 0, retryable: false)
        }
        if (200..<300).contains(http.statusCode) { return .succeeded(data) }
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let secrets = [authorization, authorization.replacing("Bearer ", with: "")]
        let error = CoachError.response(operation: operation, status: http.statusCode, body: String(decoding: data, as: UTF8.self), secrets: secrets)
        if case .serviceNotConfigured = error { return .failed(error, status: http.statusCode, retryable: false) }
        return .failed(error, status: http.statusCode, retryable: http.statusCode == 429 || http.statusCode >= 500)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data, operation: String) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CoachError.invalidResponse(operation: operation, reason: error.localizedDescription)
        }
    }

    static func json(method: String, url: URL, body: some Encodable, headers: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}

/// A LiveAvatar session token minted by the backend, scoped to one session.
nonisolated struct CoachSessionToken: Decodable, Sendable {
    let sessionId: String
    let sessionToken: String
}

/// The tutoring routes the coach screens depend on, so their logic can be tested without a network.
nonisolated protocol CoachTutorService: Sendable {
    func nextExercise(locale: String?) async throws -> NextExercise
    func preferences() async throws -> CoachPreferencesRecord
    func savePreferences(_ preferences: CoachPreferences, expectedVersion: Int) async throws -> CoachPreferencesRecord
    func memoryStatus() async throws -> CoachMemoryStatus
    /// Queues deletion of every coaching memory document; returns how many were scheduled.
    func forgetMemory() async throws -> Int
}

/// Talks to the DubIt Convex backend, which holds the OpenAI and LiveAvatar keys. The device
/// sends only the learner's Convex auth token and receives only short-lived avatar session tokens.
nonisolated struct CoachBackendClient: CoachTutorService {
    let baseURL: URL
    let tokens: any CoachAuthTokenProvider

    /// Reads the backend URL that the COACH_BACKEND_URL build setting writes into Info.plist.
    static func configured(in bundle: Bundle, tokens: any CoachAuthTokenProvider) throws -> CoachBackendClient {
        guard
            let value = bundle.object(forInfoDictionaryKey: "CoachBackendURL") as? String,
            !value.isEmpty,
            let url = URL(string: value)
        else { throw CoachError.backendNotConfigured }
        return CoachBackendClient(baseURL: url, tokens: tokens)
    }

    /// The coach roster is public, so it is the one route sent without a token.
    func characters() async throws -> [CoachCharacter] {
        struct Response: Decodable { let characters: [CoachCharacter] }
        let operation = "Loading coaches"
        let data = try await ServiceRequest.data(for: URLRequest(url: baseURL.appending(path: "coach/characters")), operation: operation)
        return try ServiceRequest.decode(Response.self, from: data, operation: operation).characters
    }

    func sessionToken(characterID: String, language: SpokenLanguage) async throws -> CoachSessionToken {
        struct Body: Encodable { let characterId: String; let language: String }
        let operation = "Starting the coach session"
        let body = Body(characterId: characterID, language: CoachConversation.avatarLanguageCode(for: language))
        let request = try ServiceRequest.json(method: "POST", url: baseURL.appending(path: "coach/session-token"), body: body, headers: [:])
        return try await send(request, as: CoachSessionToken.self, operation: operation)
    }

    func reply(characterID: String, language: SpokenLanguage, practice: CoachPracticeContext?, turns: [CoachTurn]) async throws -> CoachReply {
        struct Body: Encodable { let characterId: String; let languageName: String; let turns: [CoachTurn]; let locale: String; let lineId: String? }
        let operation = "Getting the coach's reply"
        let context = CoachConversation.replyContext(language: language, practice: practice)
        let body = Body(characterId: characterID, languageName: language.name, turns: turns, locale: context.locale, lineId: context.lineId)
        let request = try ServiceRequest.json(method: "POST", url: baseURL.appending(path: "coach/reply"), body: body, headers: [:])
        let reply = try await send(request, as: CoachReply.self, operation: operation)
        guard !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoachError.invalidResponse(operation: operation, reason: "the reply was empty")
        }
        return reply
    }

    func progress(locale: String?) async throws -> CoachProgress {
        try await send(get("tutor/progress", locale: locale), as: CoachProgress.self, operation: "Loading your progress")
    }

    func nextExercise(locale: String?) async throws -> NextExercise {
        struct Response: Decodable { let exercise: NextExercise }
        return try await send(get("tutor/next-exercise", locale: locale), as: Response.self, operation: "Choosing your next exercise").exercise
    }

    func preferences() async throws -> CoachPreferencesRecord {
        try await send(get("tutor/preferences", locale: nil), as: CoachPreferencesRecord.self, operation: "Loading your preferences")
    }

    func savePreferences(_ preferences: CoachPreferences, expectedVersion: Int) async throws -> CoachPreferencesRecord {
        struct Body: Encodable { let preferences: CoachPreferences; let expectedVersion: Int }
        let body = Body(preferences: preferences, expectedVersion: expectedVersion)
        let request = try ServiceRequest.json(method: "PUT", url: baseURL.appending(path: "tutor/preferences"), body: body, headers: [:])
        return try await send(request, as: CoachPreferencesRecord.self, operation: "Saving your preferences")
    }

    func memoryStatus() async throws -> CoachMemoryStatus {
        try await send(get("tutor/memory/status", locale: nil), as: CoachMemoryStatus.self, operation: "Checking your coaching memory")
    }

    func forgetMemory() async throws -> Int {
        struct Response: Decodable { let scheduled: Int }
        var request = URLRequest(url: baseURL.appending(path: "tutor/memory"))
        request.httpMethod = "DELETE"
        return try await send(request, as: Response.self, operation: "Forgetting your coaching memory").scheduled
    }

    private func get(_ path: String, locale: String?) -> URLRequest {
        var url = baseURL.appending(path: path)
        if let locale {
            url.append(queryItems: [URLQueryItem(name: "locale", value: locale)])
        }
        return URLRequest(url: url)
    }

    /// Adds the learner's Bearer token, throwing `signInRequired` before any request when signed out.
    private func send<Value: Decodable>(_ request: URLRequest, as type: Value.Type, operation: String) async throws -> Value {
        guard let token = try await tokens.convexAuthToken() else { throw CoachError.signInRequired }
        var authorized = request
        authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try ServiceRequest.decode(type, from: try await ServiceRequest.data(for: authorized, operation: operation), operation: operation)
    }
}
