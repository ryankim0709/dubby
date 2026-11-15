import Foundation
import os

/// JSON over HTTPS with bounded retries, shared by the coach's backend and LiveAvatar clients.
nonisolated enum ServiceRequest {
    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "coach-network")
    private static let maxAttempts = 3

    private enum Attempt {
        case succeeded(Data)
        case failed(CoachError, retryable: Bool)
    }

    /// Sends the request, retrying network failures, 429, and 5xx with exponential backoff.
    /// Other statuses fail at once with the response body, which the services use for validation messages.
    static func data(for request: URLRequest, operation: String) async throws -> Data {
        for attempt in 1... {
            switch try await send(request, operation: operation) {
            case .succeeded(let data):
                return data
            case .failed(let error, let retryable):
                guard retryable, attempt < maxAttempts else { throw error }
                logger.warning("Coach request failed, retrying. operation=\(operation, privacy: .public) attempt=\(attempt) error=\(error.localizedDescription, privacy: .public)")
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
        } catch let error as URLError where error.code != .cancelled {
            return .failed(.requestFailed(operation: operation, status: 0, body: error.localizedDescription), retryable: true)
        }
        guard let http = response as? HTTPURLResponse else {
            return .failed(.invalidResponse(operation: operation, reason: "the response wasn't HTTP"), retryable: false)
        }
        if (200..<300).contains(http.statusCode) { return .succeeded(data) }
        let error = CoachError.requestFailed(operation: operation, status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        return .failed(error, retryable: http.statusCode == 429 || http.statusCode >= 500)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data, operation: String) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CoachError.invalidResponse(operation: operation, reason: error.localizedDescription)
        }
    }

    static func jsonPost(url: URL, body: some Encodable, headers: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
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

/// Talks to the DubIt Convex backend, which holds the LiveAvatar and Anthropic keys.
nonisolated struct CoachBackendClient: Sendable {
    let baseURL: URL

    /// Reads the backend URL that the COACH_BACKEND_URL build setting writes into Info.plist.
    static func configured(in bundle: Bundle) throws -> CoachBackendClient {
        guard
            let value = bundle.object(forInfoDictionaryKey: "CoachBackendURL") as? String,
            !value.isEmpty,
            let url = URL(string: value)
        else { throw CoachError.backendNotConfigured }
        return CoachBackendClient(baseURL: url)
    }

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
        let request = try ServiceRequest.jsonPost(url: baseURL.appending(path: "coach/session-token"), body: body, headers: [:])
        return try ServiceRequest.decode(CoachSessionToken.self, from: try await ServiceRequest.data(for: request, operation: operation), operation: operation)
    }

    func reply(characterID: String, language: SpokenLanguage, turns: [CoachTurn]) async throws -> String {
        struct Body: Encodable { let characterId: String; let languageName: String; let turns: [CoachTurn] }
        struct Response: Decodable { let text: String }
        let operation = "Getting the coach's reply"
        let body = Body(characterId: characterID, languageName: language.name, turns: turns)
        let request = try ServiceRequest.jsonPost(url: baseURL.appending(path: "coach/reply"), body: body, headers: [:])
        let text = try ServiceRequest.decode(Response.self, from: try await ServiceRequest.data(for: request, operation: operation), operation: operation).text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoachError.invalidResponse(operation: operation, reason: "the reply was empty")
        }
        return text
    }
}
