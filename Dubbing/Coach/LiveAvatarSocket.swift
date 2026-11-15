import Foundation
import os

/// Audio rules for LiveAvatar's LITE socket: PCM 16-bit, 24 kHz, mono, Base64, about one second a chunk.
nonisolated enum LiveAvatarAudio {
    static let bytesPerSecond = 48_000
    static let chunkBytes = bytesPerSecond
    /// A reply longer than this is refused instead of being sent, so one response can't flood the socket.
    static let maximumBytes = 60 * bytesPerSecond
    /// How much audio may be sent ahead of real time. A short lead keeps interrupts effective and
    /// the avatar's video from being asked to render much more audio than has played.
    static let leadSeconds = 2

    /// Checks a reply's chunks before any is sent: at least one, each a non-empty run of whole
    /// samples no longer than a second, and no more than `maximumBytes` altogether.
    static func validate(chunks: [Data]) throws {
        let operation = "Playing the coach's voice"
        guard !chunks.isEmpty, chunks.allSatisfy({ !$0.isEmpty }) else { throw CoachError.invalidResponse(operation: operation, reason: "the audio was empty") }
        guard chunks.allSatisfy({ $0.count.isMultiple(of: 2) }) else { throw CoachError.invalidResponse(operation: operation, reason: "the audio wasn't whole 16-bit samples") }
        guard chunks.allSatisfy({ $0.count <= chunkBytes }) else { throw CoachError.invalidResponse(operation: operation, reason: "an audio chunk was longer than a second") }
        guard chunks.reduce(0, { $0 + $1.count }) <= maximumBytes else { throw CoachError.invalidResponse(operation: operation, reason: "the audio was longer than \(maximumBytes / bytesPerSecond) seconds") }
    }

    /// When, after the first chunk is sent, a chunk should go out: each second of audio waits
    /// until it is within `leadSeconds` of being played.
    static func sendOffset(ofChunk index: Int) -> Duration {
        .seconds(max(0, index - leadSeconds))
    }
}

/// Commands the app sends on the LITE session's WebSocket.
nonisolated enum LiveAvatarSocketCommand {
    private struct Frame: Encodable {
        let type: String
        let event_id: String
        let audio: String?
    }

    private static func encode(_ type: String, eventID: UUID, audio: Data?) throws -> String {
        let frame = Frame(type: type, event_id: eventID.uuidString.lowercased(), audio: audio?.base64EncodedString())
        return String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
    }

    /// Appends audio to the current utterance; the first chunk after a seal or interrupt opens a new one.
    static func speak(audio: Data, eventID: UUID) throws -> String { try encode("agent.speak", eventID: eventID, audio: audio) }
    static func speakEnd(eventID: UUID) throws -> String { try encode("agent.speak_end", eventID: eventID, audio: nil) }
    static func interrupt(eventID: UUID) throws -> String { try encode("agent.interrupt", eventID: eventID, audio: nil) }
    static func keepAlive(eventID: UUID) throws -> String { try encode("session.keep_alive", eventID: eventID, audio: nil) }
}

/// Events from the WebSocket that the coach reacts to.
nonisolated enum LiveAvatarSocketEvent: Equatable, Sendable {
    case connected
    case sessionDisconnected
    case speakStarted
    case speakEnded
    case speakInterrupted
    case failed(type: String, message: String)
    case unreadable(String)
    /// The socket itself ended, whether or not the server said so.
    case closed(String?)

    /// Decodes one frame; returns nil for events the coach doesn't use, such as buffer acknowledgements.
    static func decode(_ text: String) throws -> LiveAvatarSocketEvent? {
        struct Raw: Decodable {
            struct Failure: Decodable { let type: String; let message: String }
            let type: String
            let state: String?
            let error: Failure?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: Data(text.utf8))
        switch raw.type {
        case "session.state_updated":
            switch raw.state {
            case "connected": return .connected
            case "disconnected": return .sessionDisconnected
            default: return nil
            }
        case "agent.speak_started": return .speakStarted
        case "agent.speak_ended": return .speakEnded
        case "agent.speak_interrupted": return .speakInterrupted
        case "error": return .failed(type: raw.error?.type ?? "unknown", message: raw.error?.message ?? "no message")
        default: return nil
        }
    }
}

/// One WebSocket connection's text frames, so the socket's logic can be tested without a network.
nonisolated protocol AvatarSocketTransport: Sendable {
    func send(_ text: String) async throws
    /// The next text frame, or a thrown error once the connection has ended.
    func receive() async throws -> String
    func close() async
}

/// The real transport: a `URLSessionWebSocketTask`, which needs no extra package.
actor URLSessionSocketTransport: AvatarSocketTransport {
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: throw CoachError.invalidResponse(operation: "Listening to the avatar", reason: "an unknown frame type arrived")
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// The LITE session's WebSocket: sends the coach's voice to LiveAvatar to be rendered and reports
/// what the avatar is doing. It carries only the backend's reply audio, never the learner's recording.
actor LiveAvatarSocket {
    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "coach-avatar")

    nonisolated let events: AsyncStream<LiveAvatarSocketEvent>
    private let continuation: AsyncStream<LiveAvatarSocketEvent>.Continuation
    private let transport: any AvatarSocketTransport
    private var receiveTask: Task<Void, Never>?
    private var isConnected = false
    private var isClosing = false
    private var isSending = false
    /// Bumped by every interrupt and by close, so a reply that is still being paced out stops.
    private var generation = 0

    init(transport: any AvatarSocketTransport) {
        self.transport = transport
        (events, continuation) = AsyncStream.makeStream()
    }

    /// Starts reading frames. Commands are accepted once the server reports `connected`.
    func start() {
        guard receiveTask == nil else { return }
        receiveTask = Task { await receiveFrames() }
    }

    /// Sends one reply's chunks, paced, and seals the utterance. Returns early, without sealing,
    /// when the utterance is interrupted; a cancelled task throws `CancellationError`.
    func speak(chunks: [Data]) async throws {
        guard isConnected else { throw CoachError.avatarDisconnected }
        guard !isSending else { throw CoachError.avatarBusy }
        try LiveAvatarAudio.validate(chunks: chunks)
        isSending = true
        defer { isSending = false }
        let utterance = generation
        let clock = ContinuousClock()
        let start = clock.now
        let utteranceID = UUID()
        for (index, chunk) in chunks.enumerated() {
            try await clock.sleep(until: start + LiveAvatarAudio.sendOffset(ofChunk: index))
            guard generation == utterance else { return }
            try await transport.send(try LiveAvatarSocketCommand.speak(audio: chunk, eventID: index == 0 ? utteranceID : UUID()))
        }
        guard generation == utterance else { return }
        try await transport.send(try LiveAvatarSocketCommand.speakEnd(eventID: UUID()))
    }

    func interrupt() async throws {
        generation += 1
        try await transport.send(try LiveAvatarSocketCommand.interrupt(eventID: UUID()))
    }

    func keepAlive() async throws {
        try await transport.send(try LiveAvatarSocketCommand.keepAlive(eventID: UUID()))
    }

    /// Stops any speech in flight and closes the socket.
    func close() async {
        isClosing = true
        generation += 1
        if isConnected {
            do {
                try await transport.send(try LiveAvatarSocketCommand.interrupt(eventID: UUID()))
            } catch {
                Self.logger.warning("Interrupting the avatar while closing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        isConnected = false
        receiveTask?.cancel()
        await transport.close()
        continuation.finish()
    }

    private func receiveFrames() async {
        while !Task.isCancelled {
            let frame: String
            do {
                frame = try await transport.receive()
            } catch {
                if !isClosing { continuation.yield(.closed(error.localizedDescription)) }
                break
            }
            do {
                guard let event = try LiveAvatarSocketEvent.decode(frame) else { continue }
                if event == .connected { isConnected = true }
                if event == .sessionDisconnected { isConnected = false }
                continuation.yield(event)
            } catch {
                continuation.yield(.unreadable(error.localizedDescription))
            }
        }
        isConnected = false
        continuation.finish()
    }
}
