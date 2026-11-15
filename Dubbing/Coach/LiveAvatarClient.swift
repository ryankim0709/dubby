import Foundation

/// Where the app joins a started LiveAvatar session: the LiveKit room that carries the avatar's
/// video and audio, and the WebSocket that takes the coach's voice.
nonisolated struct LiveAvatarConnection: Hashable, Sendable {
    let sessionID: String
    let livekitURL: String
    let livekitClientToken: String
    let webSocketURL: URL
}

/// Starts and stops a LiveAvatar LITE session with its short-lived session token. Shapes follow
/// https://docs.liveavatar.com/openapi.json and the LITE mode docs, and the start and stop bodies
/// match LiveKit's own LiveAvatar plugin. In LITE mode LiveAvatar only renders audio the app sends
/// over the socket: it runs no speech recognition, language model or voice of its own.
nonisolated struct LiveAvatarClient: Sendable {
    private static let apiBase = URL(string: "https://api.liveavatar.com")!
    /// LiveAvatar wraps every payload as {code, data, message}; its web SDK treats 1000 as success.
    private static let successCode = 1000

    let sessionToken: String
    let sessionID: String

    func start() async throws -> LiveAvatarConnection {
        struct Started: Decodable {
            let session_id: String
            let livekit_url: String
            let livekit_client_token: String
            let ws_url: String?
        }
        struct Body: Encodable { let session_id: String }
        let operation = "Starting the avatar"
        let started = try await post("v1/sessions/start", operation: operation, body: Body(session_id: sessionID), payload: Started.self)
        guard let socket = started.ws_url.flatMap(URL.init(string:)) else {
            throw CoachError.invalidResponse(operation: operation, reason: "the session has no audio socket, so it isn't a LITE session")
        }
        return LiveAvatarConnection(sessionID: started.session_id, livekitURL: started.livekit_url, livekitClientToken: started.livekit_client_token, webSocketURL: socket)
    }

    func stop() async throws {
        struct Body: Encodable { let session_id: String; let reason: String }
        _ = try await post("v1/sessions/stop", operation: "Ending the avatar session", body: Body(session_id: sessionID, reason: "USER_DISCONNECTED"), payload: Empty?.self)
    }

    private struct Empty: Decodable {}

    private struct Envelope<Payload: Decodable>: Decodable {
        let code: Int
        let message: String?
        let data: Payload
    }

    private func post<Payload: Decodable>(_ path: String, operation: String, body: some Encodable, payload: Payload.Type) async throws -> Payload {
        let request = try ServiceRequest.json(method: "POST", url: Self.apiBase.appending(path: path), body: body, headers: ["Authorization": "Bearer \(sessionToken)"])
        let data = try await ServiceRequest.data(for: request, operation: operation)
        let envelope = try ServiceRequest.decode(Envelope<Payload>.self, from: data, operation: operation)
        guard envelope.code == Self.successCode else {
            throw CoachError.invalidResponse(operation: operation, reason: "code \(envelope.code): \(envelope.message ?? "no message")")
        }
        return envelope.data
    }
}
