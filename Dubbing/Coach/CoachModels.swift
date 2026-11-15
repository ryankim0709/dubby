import Foundation

/// A coach the learner can pick. The backend owns each character's avatar, voice, and persona.
nonisolated struct CoachCharacter: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let summary: String
}

nonisolated enum CoachSpeaker: String, Codable, Hashable, Sendable {
    case learner
    case coach
}

nonisolated struct CoachTurn: Codable, Hashable, Sendable {
    let role: CoachSpeaker
    let text: String
}

/// What the conversation is doing right now; one state at a time, so the mic and the avatar never overlap.
enum CoachActivity: Equatable {
    case idle
    case listening
    case transcribing
    case thinking
    case speaking
}

nonisolated enum CoachError: LocalizedError, Equatable {
    case backendNotConfigured
    case signInRequired
    case offline(operation: String)
    case invalidRequest(operation: String, message: String)
    case notFound(operation: String)
    case versionConflict
    case providerFailed(operation: String, message: String)
    case providerTimeout(operation: String)
    case serviceNotConfigured(operation: String)
    case requestFailed(operation: String, status: Int, body: String)
    case invalidResponse(operation: String, reason: String)
    case noSpeechHeard
    case avatarDisconnected

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            "The coach backend isn't set up for this build yet. Set COACH_BACKEND_URL to the Convex site URL and run again."
        case .signInRequired:
            "Sign in to use coaching. Your coach needs your account to see your practice."
        case .offline(let operation):
            "\(operation) needs an internet connection. Check your connection and try again."
        case .invalidRequest(let operation, let message):
            "\(operation) was rejected: \(message)"
        case .notFound(let operation):
            "\(operation) isn't available yet."
        case .versionConflict:
            "Your preferences changed somewhere else."
        case .providerFailed(let operation, let message):
            "\(operation) failed because a coaching service didn't answer: \(message)"
        case .providerTimeout(let operation):
            "\(operation) took too long because the coaching service didn't answer in time. Try again."
        case .serviceNotConfigured(let operation):
            "\(operation) isn't available because coaching isn't fully set up on the server yet."
        case .requestFailed(let operation, let status, let body):
            "\(operation) failed with status \(status): \(body)"
        case .invalidResponse(let operation, let reason):
            "\(operation) returned something unexpected: \(reason)."
        case .noSpeechHeard:
            "I didn't catch any words. Hold the button and speak a little closer to the mic."
        case .avatarDisconnected:
            "The coach's video call ended. Start the session again to keep talking."
        }
    }

    private static let maximumBodyLength = 300

    /// Maps a non-success HTTP response onto a typed error. `secrets` are request credentials that
    /// must not survive into an error message, in case the server echoes them back.
    static func response(operation: String, status: Int, body: String, secrets: [String]) -> CoachError {
        var message = body
        for secret in secrets where !secret.isEmpty {
            message = message.replacing(secret, with: "[redacted]")
        }
        let envelope: CoachErrorEnvelope?
        do {
            envelope = try JSONDecoder().decode(CoachErrorEnvelope.self, from: Data(body.utf8))
        } catch {
            // A proxy or gateway can answer with something other than the backend's JSON envelope.
            envelope = nil
        }
        let detail = String((envelope?.error ?? message).prefix(maximumBodyLength))
        switch (status, envelope?.code) {
        case (400, _): return .invalidRequest(operation: operation, message: detail)
        case (401, _): return .signInRequired
        case (404, _): return .notFound(operation: operation)
        case (409, "version_conflict"): return .versionConflict
        case (502, _): return .providerFailed(operation: operation, message: detail)
        case (504, "provider_timeout"): return .providerTimeout(operation: operation)
        case (503, "not_configured"): return .serviceNotConfigured(operation: operation)
        default: return .requestFailed(operation: operation, status: status, body: detail)
        }
    }

    /// The backend's error code for this failure, or nil when it didn't come from one.
    var backendCode: String? {
        switch self {
        case .signInRequired: "unauthenticated"
        case .invalidRequest: "invalid_request"
        case .notFound: "not_found"
        case .versionConflict: "version_conflict"
        case .providerFailed: "provider_failed"
        case .providerTimeout: "provider_timeout"
        case .serviceNotConfigured: "not_configured"
        default: nil
        }
    }

    /// Whether trying the same turn again can succeed without the learner changing anything.
    var isRetryable: Bool {
        switch self {
        case .providerFailed, .providerTimeout, .serviceNotConfigured, .offline, .requestFailed: true
        default: false
        }
    }

    /// Whether the device had no usable connection, as opposed to a request that failed in flight.
    static func isOffline(_ error: URLError) -> Bool {
        [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .networkConnectionLost].contains(error.code)
    }
}

/// Pure conversation rules, kept apart from the view so they can be tested.
nonisolated enum CoachConversation {
    /// The learner's words as one line, or nil when the transcript held nothing to send.
    static func learnerText(from words: [TranscribedWord]) -> String? {
        let text = words.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// LiveAvatar takes a two-letter language for the avatar's voice, such as "es" for es-ES.
    static func avatarLanguageCode(for language: SpokenLanguage) -> String {
        Locale(identifier: language.identifier).language.languageCode?.identifier ?? language.identifier
    }
}
