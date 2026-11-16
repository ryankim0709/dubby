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
        // The server already retried a timeout once, and a missing key won't appear by asking again.
        switch error {
        case .serviceNotConfigured, .providerTimeout: return .failed(error, status: http.statusCode, retryable: false)
        default: break
        }
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
    func memoryItems() async throws -> [MemoryItem]
    /// Turns coaching memory off and queues deletion of every memory document; returns how many were scheduled.
    func forgetMemory() async throws -> Int
}

/// Talks to the Dubby Convex backend, which holds the OpenAI and LiveAvatar keys. The device
/// sends only the learner's Convex auth token and receives only short-lived avatar session tokens.
nonisolated struct CoachBackendClient: CoachTutorService {
    let baseURL: URL
    let tokens: any CoachAuthTokenProvider
    /// A failure to ask the backend to simulate; always nil outside QA runs of a debug build.
    let qaFault: CoachQAFault?

    static func configured(in bundle: Bundle, tokens: any CoachAuthTokenProvider) throws -> CoachBackendClient {
        guard let url = configuredBaseURL(in: bundle) else { throw CoachError.backendNotConfigured }
        return CoachBackendClient(baseURL: url, tokens: tokens, qaFault: CoachQAOptions.current.fault)
    }

    /// The backend URL that the COACH_BACKEND_URL build setting writes into Info.plist, or nil when it's unset.
    static func configuredBaseURL(in bundle: Bundle) -> URL? {
        guard let value = bundle.object(forInfoDictionaryKey: "CoachBackendURL") as? String, !value.isEmpty else { return nil }
        return URL(string: value)
    }

    /// The coach roster is public, so it is the one route sent without a token.
    func characters() async throws -> [CoachCharacter] {
        struct Response: Decodable { let characters: [CoachCharacter] }
        let operation = "Loading coaches"
        let data = try await ServiceRequest.data(for: URLRequest(url: baseURL.appending(path: "coach/characters")), operation: operation)
        return try ServiceRequest.decode(Response.self, from: data, operation: operation).characters
    }

    func createCheckout() async throws -> WhopCheckout {
        var request = URLRequest(url: baseURL.appending(path: "billing/checkout"))
        request.httpMethod = "POST"
        return try await send(request, as: WhopCheckout.self, operation: "Opening Whop checkout")
    }

    func sessionToken(characterID: String, language: SpokenLanguage) async throws -> CoachSessionToken {
        struct Body: Encodable { let characterId: String; let language: String }
        let operation = "Starting the coach session"
        let body = Body(characterId: characterID, language: CoachConversation.avatarLanguageCode(for: language))
        let request = try ServiceRequest.json(method: "POST", url: baseURL.appending(path: "coach/session-token"), body: body, headers: [:])
        return try await send(request, as: CoachSessionToken.self, operation: operation)
    }

    func takeCoachAvatarSession(characterID: String) async throws -> SimliSessionToken {
        struct Body: Encodable { let characterId: String }
        let operation = "Starting the coach video"
        let request = try ServiceRequest.json(method: "POST", url: baseURL.appending(path: "tutor/take-coach/avatar-session"), body: Body(characterId: characterID), headers: [:])
        let session = try await send(request, as: SimliSessionToken.self, operation: operation)
        guard !session.sessionToken.isEmpty else {
            throw CoachError.invalidResponse(operation: operation, reason: "Simli returned an empty session token")
        }
        return session
    }

    func reply(characterID: String, language: SpokenLanguage, turns: [CoachTurn]) async throws -> CoachReply {
        struct Body: Encodable { let characterId: String; let languageName: String; let locale: String; let audio: Bool; let turns: [CoachTurn] }
        let operation = "Getting the coach's reply"
        // The avatar is rendered from the reply's audio, so the voice is always asked for.
        let body = Body(characterId: characterID, languageName: language.name, locale: language.identifier, audio: true, turns: turns)
        let request = try ServiceRequest.json(method: "POST", url: baseURL.appending(path: "coach/reply"), body: body, headers: [:])
        let reply = try await send(request, as: CoachReply.self, operation: operation)
        guard !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoachError.invalidResponse(operation: operation, reason: "the reply was empty")
        }
        return reply
    }

    /// Opens a live tutor session about one of the learner's scored dubs. The backend reads the dub's score sheet
    /// itself; the app sends only which dub.
    func liveTutorSession(clientDubID: String) async throws -> LiveTutorGrant {
        struct Body: Encodable { let clientDubId: String }
        let operation = "Starting your tutor"
        let request = try ServiceRequest.json(method: "POST", url: baseURL.appending(path: "tutor/live-session"), body: Body(clientDubId: clientDubID), headers: [:])
        let grant = try await send(request, as: LiveTutorGrant.self, operation: operation)
        guard !grant.clientSecret.isEmpty, !grant.model.isEmpty else {
            throw CoachError.invalidResponse(operation: operation, reason: "the session had no key or model")
        }
        return grant
    }

    /// Dialogue grounds the persona; reference pitch picks an approximate built-in voice, never a voice clone.
    func takeCoachSession(sceneTitle: String, characterName: String, locale: String, characterLines: [String], referencePitchHz: Double?) async throws -> LiveTutorGrant {
        struct Body: Encodable {
            let sceneTitle: String
            let characterName: String
            let locale: String
            let characterLines: [String]
            let referencePitchHz: Double?
        }
        let operation = "Starting your take coach"
        let body = Body(sceneTitle: sceneTitle, characterName: characterName, locale: locale, characterLines: characterLines, referencePitchHz: referencePitchHz)
        let request = try ServiceRequest.json(method: "POST", url: baseURL.appending(path: "tutor/take-coach"), body: body, headers: [:])
        let grant = try await send(request, as: LiveTutorGrant.self, operation: operation)
        guard !grant.clientSecret.isEmpty, !grant.model.isEmpty else {
            throw CoachError.invalidResponse(operation: operation, reason: "the session had no key or model")
        }
        return grant
    }

    /// Translates a section's lines, in spoken order, into the language the learner dubs in. One request carries the
    /// whole section so each line is translated with the rest of the conversation.
    func translateScript(sceneTitle: String, from source: SpokenLanguage, to target: SpokenLanguage, lines: [ScriptTranslationLine]) async throws -> [String] {
        struct Body: Encodable { let sourceLocale: String; let targetLocale: String; let sceneTitle: String; let lines: [ScriptTranslationLine] }
        struct Response: Decodable { let locale: String; let lines: [String] }
        let operation = "Translating the script"
        let body = Body(sourceLocale: source.identifier, targetLocale: target.identifier, sceneTitle: sceneTitle, lines: lines)
        var request = try ServiceRequest.json(method: "POST", url: baseURL.appending(path: "scripts/translate"), body: body, headers: [:])
        // The backend retries OpenAI up to three times at 30 seconds each before it answers.
        request.timeoutInterval = 100
        let response = try await send(request, as: Response.self, operation: operation)
        guard response.locale == target.identifier else {
            throw CoachError.invalidResponse(operation: operation, reason: "the translation's language doesn't match \(target.name)")
        }
        // Translations are paired with line timings by position, so a missing or empty line can't be used.
        guard response.lines.count == lines.count,
              response.lines.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CoachError.invalidResponse(operation: operation, reason: "it didn't have one non-empty translation for each of the \(lines.count) lines")
        }
        return response.lines
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

    func memoryItems() async throws -> [MemoryItem] {
        struct Response: Decodable { let items: [MemoryItem] }
        return try await send(get("tutor/memory", locale: nil), as: Response.self, operation: "Loading your coaching memory").items
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
        if let qaFault { authorized.setValue(qaFault.rawValue, forHTTPHeaderField: CoachQAFault.header) }
        return try ServiceRequest.decode(type, from: try await ServiceRequest.data(for: authorized, operation: operation), operation: operation)
    }
}
