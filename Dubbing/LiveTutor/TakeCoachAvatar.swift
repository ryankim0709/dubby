import Foundation
import LiveKit
import os

/// The coach character's face in the take coach pop-up: a LiveAvatar LITE session that lip-syncs the coach's spoken
/// tips. LiveAvatar renders only the audio the app sends it, so it never hears the learner. One session serves the
/// whole studio visit; the avatar's voice reaches the learner through the session's LiveKit room.
@MainActor
@Observable
final class TakeCoachAvatar {
    /// The avatar's video, once the room delivers it.
    private(set) var videoTrack: RemoteVideoTrack?
    /// True while the avatar's socket accepts speech.
    private(set) var isLive = false

    private let backend: CoachBackendClient
    private let characterID: String
    private let language: SpokenLanguage
    private let room = AvatarRoom()
    private var client: LiveAvatarClient?
    private var socket: LiveAvatarSocket?
    private var speechTask: Task<Void, Never>?
    private var isSpeaking = false
    private var hasEnded = false

    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "take-coach-avatar")
    private static let keepAliveInterval = Duration.seconds(60)
    private static let connectTimeout = Duration.seconds(20)

    init(backend: CoachBackendClient, characterID: String, language: SpokenLanguage) {
        self.backend = backend
        self.characterID = characterID
        self.language = language
    }

    /// Starts the session and follows it until it ends, then releases it so it stops spending credits.
    func run() async {
        do {
            try await start()
        } catch {
            if !hasEnded {
                Self.logger.warning("The take coach's avatar couldn't start. character=\(self.characterID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
            await end()
            return
        }
        guard let socket else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.followRoom() }
            group.addTask { await self.followSocket(socket) }
            group.addTask { await self.keepAlive(socket) }
            // Any of them finishing means the session is over, so the rest stop too.
            await group.next()
            group.cancelAll()
        }
        await end()
    }

    /// Has the avatar say one reply of 24 kHz mono PCM16.
    func speak(pcm: Data) {
        guard isLive, let socket else { return }
        let chunks = LiveAvatarAudio.chunks(of: pcm)
        speechTask?.cancel()
        speechTask = Task {
            do {
                try await socket.speak(chunks: chunks)
            } catch is CancellationError {
                return
            } catch {
                Self.logger.warning("The avatar couldn't say the coach's tip. error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Cuts the avatar off, for when the learner records, plays their take, or moves on.
    func interrupt() {
        guard isLive, let socket, speechTask != nil || isSpeaking else { return }
        speechTask?.cancel()
        speechTask = nil
        Task {
            do {
                try await socket.interrupt()
            } catch {
                Self.logger.warning("Interrupting the avatar failed. error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Ends the session for good. The studio owns the audio session, so it is left active.
    func end() async {
        guard !hasEnded else { return }
        hasEnded = true
        speechTask?.cancel()
        isLive = false
        videoTrack = nil
        await socket?.close()
        if let client { await Self.stop(client) }
        await room.disconnect()
    }

    private func start() async throws {
        let token = try await backend.sessionToken(characterID: characterID, language: language)
        let client = LiveAvatarClient(sessionToken: token.sessionToken, sessionID: token.sessionId)
        let started = try await client.start()
        // A studio closed while the session was starting has already ended, so this session is stopped here.
        guard !hasEnded else {
            await Self.stop(client)
            throw CancellationError()
        }
        self.client = client
        let socket = LiveAvatarSocket(transport: URLSessionSocketTransport(url: started.webSocketURL))
        self.socket = socket
        await socket.start()
        try await room.connect(to: started)
        guard !hasEnded else {
            await room.disconnect()
            throw CancellationError()
        }
    }

    private func followRoom() async {
        for await update in room.updates {
            switch update {
            case .videoTrack(let track):
                videoTrack = track
            case .disconnected(let reason):
                Self.logger.info("The avatar's room closed. reason=\(reason ?? "none", privacy: .public)")
                return
            }
        }
    }

    private func followSocket(_ socket: LiveAvatarSocket) async {
        for await event in socket.events {
            switch event {
            case .connected:
                isLive = true
            case .speakStarted:
                isSpeaking = true
            case .speakEnded, .speakInterrupted:
                isSpeaking = false
            case .failed(let type, let message):
                Self.logger.warning("The avatar reported a problem. type=\(type, privacy: .public) message=\(message, privacy: .public)")
            case .unreadable(let reason):
                Self.logger.warning("The avatar sent an unreadable event. reason=\(reason, privacy: .public)")
            case .sessionDisconnected, .closed:
                return
            }
        }
    }

    /// Pings the session every minute. Returning ends the session, which is how one whose socket never connects
    /// stops spending credits.
    private func keepAlive(_ socket: LiveAvatarSocket) async {
        guard await pause(for: Self.connectTimeout) else { return }
        guard isLive else {
            Self.logger.warning("The avatar's socket didn't connect in time, so its session ends.")
            return
        }
        repeat {
            do {
                try await socket.keepAlive()
            } catch {
                Self.logger.warning("The avatar's keep-alive failed. error=\(error.localizedDescription, privacy: .public)")
            }
        } while await pause(for: Self.keepAliveInterval)
    }

    private static func stop(_ client: LiveAvatarClient) async {
        do {
            try await client.stop()
        } catch {
            logger.warning("Stopping the avatar's LiveAvatar session failed. error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
