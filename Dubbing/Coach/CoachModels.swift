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
    case requestFailed(operation: String, status: Int, body: String)
    case invalidResponse(operation: String, reason: String)
    case noSpeechHeard
    case avatarDisconnected

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            "The coach backend isn't set up for this build yet. Set COACH_BACKEND_URL to the Convex site URL and run again."
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
