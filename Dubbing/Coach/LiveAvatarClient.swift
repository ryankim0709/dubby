import Foundation

/// Where the app joins a started LiveAvatar session.
nonisolated struct LiveAvatarConnection: Hashable, Sendable {
    let sessionID: String
    let livekitURL: String
    let livekitClientToken: String
}

/// Starts, keeps alive, and stops a LiveAvatar session with its short-lived session token, the way
/// LiveAvatar's official web SDK does. Shapes follow https://docs.liveavatar.com/openapi.json.
nonisolated struct LiveAvatarClient: Sendable {
    private static let apiBase = URL(string: "https://api.liveavatar.com")!
    /// LiveAvatar wraps every payload as {code, data, message}; its web SDK treats 1000 as success.
    private static let successCode = 1000

    let sessionToken: String

    func start() async throws -> LiveAvatarConnection {
        struct Started: Decodable {
            let session_id: String
            let livekit_url: String
            let livekit_client_token: String
        }
        let started = try await post("v1/sessions/start", operation: "Starting the avatar", payload: Started.self)
        return LiveAvatarConnection(sessionID: started.session_id, livekitURL: started.livekit_url, livekitClientToken: started.livekit_client_token)
    }

    /// Sessions end after five idle minutes unless pinged; the web SDK pings every minute.
    func keepAlive() async throws {
        _ = try await post("v1/sessions/keep-alive", operation: "Keeping the avatar session alive", payload: Empty?.self)
    }

    func stop() async throws {
        _ = try await post("v1/sessions/stop", operation: "Ending the avatar session", payload: Empty?.self)
    }

    private struct Empty: Decodable {}

    private struct Envelope<Payload: Decodable>: Decodable {
        let code: Int
        let message: String?
        let data: Payload
    }

    private func post<Payload: Decodable>(_ path: String, operation: String, payload: Payload.Type) async throws -> Payload {
        var request = URLRequest(url: Self.apiBase.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        let data = try await ServiceRequest.data(for: request, operation: operation)
        let envelope = try ServiceRequest.decode(Envelope<Payload>.self, from: data, operation: operation)
        guard envelope.code == Self.successCode else {
            throw CoachError.invalidResponse(operation: operation, reason: "code \(envelope.code): \(envelope.message ?? "no message")")
        }
        return envelope.data
    }
}

/// Commands the app sends on the LiveKit `agent-control` topic.
nonisolated enum LiveAvatarCommand {
    static let topic = "agent-control"

    /// Makes the avatar say `text` word for word, with no LLM of its own involved. The app never sends
    /// `avatar.speak_response`, which would make LiveAvatar write the reply itself.
    static func speakText(_ text: String, eventID: UUID) throws -> Data {
        struct Payload: Encodable { let event_id: String; let event_type: String; let text: String }
        return try JSONEncoder().encode(Payload(event_id: eventID.uuidString.lowercased(), event_type: "avatar.speak_text", text: text))
    }

    static func interrupt() throws -> Data {
        struct Payload: Encodable { let event_type: String }
        return try JSONEncoder().encode(Payload(event_type: "avatar.interrupt"))
    }
}

/// Server events the coach reacts to, received on the LiveKit `agent-response` topic.
nonisolated enum LiveAvatarEvent: Equatable, Sendable {
    static let topic = "agent-response"
    /// The LiveKit participant that publishes the avatar's video and audio.
    static let avatarParticipantIdentity = "heygen"

    case avatarStartedSpeaking
    case avatarStoppedSpeaking
    case sessionStopped(reason: String)

    /// Decodes one event; returns nil for event types the coach doesn't use, such as transcriptions.
    static func decode(_ data: Data) throws -> LiveAvatarEvent? {
        struct Raw: Decodable { let event_type: String; let stop_reason: String? }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        switch raw.event_type {
        case "avatar.speak_started": return .avatarStartedSpeaking
        case "avatar.speak_ended": return .avatarStoppedSpeaking
        case "session.stopped": return .sessionStopped(reason: raw.stop_reason ?? "unknown")
        default: return nil
        }
    }
}
