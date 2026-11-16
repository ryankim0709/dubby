import AVFoundation
import Foundation

nonisolated struct SimliSessionToken: Decodable, Sendable {
    let sessionToken: String

    func socketURL() throws -> URL {
        guard !sessionToken.isEmpty else {
            throw CoachError.invalidResponse(operation: "Starting the coach video", reason: "Simli returned an empty session token")
        }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.simli.ai"
        components.path = "/compose/webrtc/livekit"
        components.queryItems = [URLQueryItem(name: "session_token", value: sessionToken)]
        guard let url = components.url else {
            throw CoachError.invalidResponse(operation: "Starting the coach video", reason: "the Simli session URL couldn't be formed")
        }
        return url
    }
}

nonisolated struct SimliRoomConnection: Equatable, Sendable {
    let url: String
    let token: String
}

/// Simli's Compose protocol mixes JSON connection details with plain-text lifecycle signals.
nonisolated enum SimliAvatarEvent: Equatable, Sendable {
    case room(SimliRoomConnection)
    case ready
    case speaking
    case silent
    case closing(String)
    case stopped
    case closed(String?)

    static func decode(_ text: String) throws -> SimliAvatarEvent? {
        switch text {
        case "START": return .ready
        case "SPEAK": return .speaking
        case "SILENT": return .silent
        case "STOP": return .stopped
        default: break
        }
        if text.hasPrefix("CLOSING REASON: ") {
            return .closing(String(text.dropFirst("CLOSING REASON: ".count)))
        }
        if ["ERROR", "RATE LIMIT", "STOP REASON", "CLIENT NOT CONNECTED"].contains(where: text.hasPrefix) {
            throw CoachError.providerFailed(operation: "Playing the coach video", message: text)
        }
        guard text.hasPrefix("{") else { return nil }
        struct Message: Decodable {
            let livekit_url: String?
            let livekit_token: String?
        }
        let message = try JSONDecoder().decode(Message.self, from: Data(text.utf8))
        guard message.livekit_url != nil || message.livekit_token != nil else { return nil }
        guard let url = message.livekit_url, let parsed = URL(string: url), parsed.scheme == "wss", parsed.host != nil,
              let token = message.livekit_token, !token.isEmpty else {
            throw CoachError.invalidResponse(operation: "Starting the coach video", reason: "Simli returned invalid LiveKit connection details")
        }
        return .room(SimliRoomConnection(url: url, token: token))
    }
}

/// Simli takes raw mono PCM16 at 16 kHz; OpenAI Realtime produces the same samples at 24 kHz.
nonisolated enum SimliAudio {
    static let sampleRate = 16_000.0
    static let chunkBytes = 6_000

    static func resample(realtimePCM: Data) throws -> Data {
        let operation = "Preparing the coach video"
        guard !realtimePCM.isEmpty, realtimePCM.count.isMultiple(of: 2), realtimePCM.count <= 60 * 48_000 else {
            throw CoachError.invalidResponse(operation: operation, reason: "the coach's audio must contain whole PCM16 samples and last at most a minute")
        }
        let samples = LiveTutorRealtime.samples(fromPCM16: realtimePCM)
        let frames = AVAudioFrameCount(samples.count)
        let capacity = AVAudioFrameCount((Double(samples.count) * sampleRate / LiveTutorRealtime.sampleRate).rounded(.up)) + 64
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: LiveTutorRealtime.sampleRate, channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames),
              let inputChannel = input.floatChannelData?[0],
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw CoachError.invalidResponse(operation: operation, reason: "the coach's audio couldn't be buffered for Simli")
        }
        input.frameLength = frames
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { inputChannel.update(from: base, count: samples.count) }
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0, let channel = output.int16ChannelData?[0] else {
            throw CoachError.invalidResponse(operation: operation, reason: "converting the coach's audio to 16 kHz failed: \(error?.localizedDescription ?? "no samples were produced")")
        }
        return Data(bytes: channel, count: Int(output.frameLength) * 2)
    }
}

nonisolated protocol SimliSocketTransport: AvatarSocketTransport {
    func send(_ data: Data) async throws
}

/// Owns the Compose socket. Only the coach's reply audio is sent; the microphone is never published.
actor SimliAvatarSocket {
    nonisolated let events: AsyncStream<SimliAvatarEvent>
    private let continuation: AsyncStream<SimliAvatarEvent>.Continuation
    private let transport: any SimliSocketTransport
    private var receiveTask: Task<Void, Never>?
    private var isReady = false
    private var isClosed = false
    private var generation = 0

    init(transport: any SimliSocketTransport) {
        self.transport = transport
        (events, continuation) = AsyncStream.makeStream()
    }

    func start() {
        guard receiveTask == nil, !isClosed else { return }
        receiveTask = Task { await receiveFrames() }
    }

    func speak(realtimePCM: Data) async throws {
        guard isReady, !isClosed else { throw CoachError.avatarDisconnected }
        let pcm = try SimliAudio.resample(realtimePCM: realtimePCM)
        let utterance = generation
        for offset in stride(from: 0, to: pcm.count, by: SimliAudio.chunkBytes) {
            try Task.checkCancellation()
            guard generation == utterance, !isClosed else { return }
            try await transport.send(pcm.subdata(in: offset..<min(offset + SimliAudio.chunkBytes, pcm.count)))
        }
    }

    func interrupt() async throws {
        generation += 1
        guard isReady, !isClosed else { return }
        try await transport.send("SKIP")
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        isReady = false
        generation += 1
        receiveTask?.cancel()
        await transport.close()
        continuation.finish()
    }

    private func receiveFrames() async {
        do {
            while !Task.isCancelled {
                guard let event = try SimliAvatarEvent.decode(try await transport.receive()) else { continue }
                if event == .ready { isReady = true }
                continuation.yield(event)
                if event == .stopped { break }
            }
        } catch is CancellationError {
            // The owner closes the socket when the learner leaves the studio.
        } catch {
            if !isClosed { continuation.yield(.closed(error.localizedDescription)) }
        }
        await close()
    }
}
