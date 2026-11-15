import Foundation

/// The Realtime session the backend opened for one dub: an ephemeral key bound to the tutor's instructions.
nonisolated struct LiveTutorGrant: Decodable, Sendable {
    let clientSecret: String
    /// Seconds since the epoch; the key only needs to outlive opening the socket.
    let expiresAt: Double
    let model: String
}

/// Wire rules for OpenAI's Realtime WebSocket (GA interface), checked against developers.openai.com on 2026-11-15.
nonisolated enum LiveTutorRealtime {
    /// PCM 16-bit little-endian mono at 24 kHz is the only PCM the API takes, in both directions.
    static let sampleRate: Double = 24_000
    static let bytesPerFrame = 2

    static func socketURL(model: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.openai.com"
        components.path = "/v1/realtime"
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else {
            throw CoachError.invalidResponse(operation: "Starting your tutor", reason: "the model name doesn't fit in a URL")
        }
        return url
    }

    /// OpenAI documents client-side ephemeral keys as a WebSocket subprotocol rather than an Authorization header.
    static func subprotocols(clientSecret: String) -> [String] {
        ["realtime", "openai-insecure-api-key.\(clientSecret)"]
    }

    /// Converts the tutor's PCM to samples for the player; a trailing odd byte isn't a whole sample and is dropped.
    static func samples(fromPCM16 data: Data) -> [Float] {
        let count = data.count / bytesPerFrame
        return (0..<count).map { index in
            let low = UInt16(data[data.startIndex + index * 2])
            let high = UInt16(data[data.startIndex + index * 2 + 1])
            return Float(Int16(bitPattern: low | high << 8)) / Float(Int16.max)
        }
    }
}

/// Events the app sends on the Realtime socket.
nonisolated enum LiveTutorClientEvent {
    private struct Append: Encodable {
        let type = "input_audio_buffer.append"
        let audio: String
    }

    private struct CreateResponse: Encodable {
        let type = "response.create"
    }

    private struct TargetedResponse: Encodable {
        struct Options: Encodable {
            struct Function: Encodable {
                let type = "function"
                let name: String
            }

            let output_modalities: [String]
            let tool_choice: ToolChoice
            /// Echoed back in `response.created`, so late answers about an earlier take can be told apart.
            let metadata: [String: String]
        }

        enum ToolChoice: Encodable {
            case none
            case function(String)

            func encode(to encoder: any Encoder) throws {
                switch self {
                case .none:
                    var container = encoder.singleValueContainer()
                    try container.encode("none")
                case .function(let name):
                    try Options.Function(name: name).encode(to: encoder)
                }
            }
        }

        let type = "response.create"
        let response: Options
    }

    private struct CancelResponse: Encodable {
        let type = "response.cancel"
    }

    private struct CreateItem<Item: Encodable>: Encodable {
        let type = "conversation.item.create"
        let item: Item
    }

    private struct UserMessage: Encodable {
        struct Part: Encodable {
            let type: String
            let text: String?
            let audio: String?
        }

        let type = "message"
        let role = "user"
        let content: [Part]
    }

    private struct FunctionCallOutput: Encodable {
        let type = "function_call_output"
        let call_id: String
        let output: String
    }

    private struct Truncate: Encodable {
        let type = "conversation.item.truncate"
        let item_id: String
        let content_index: Int
        let audio_end_ms: Int
    }

    private static func encode(_ event: some Encodable) throws -> String {
        String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    }

    /// Adds microphone audio to the input buffer; the server's turn detection decides when a turn ends.
    static func appendAudio(_ pcm: Data) throws -> String { try encode(Append(audio: pcm.base64EncodedString())) }

    /// Asks the tutor to speak without waiting for the learner, which opens the session.
    static func createResponse() throws -> String { try encode(CreateResponse()) }

    /// Adds one recorded take to the conversation, with what was measured about it, without asking for a reply.
    static func take(note: String, pcm: Data) throws -> String {
        try encode(CreateItem(item: UserMessage(content: [
            UserMessage.Part(type: "input_text", text: note, audio: nil),
            UserMessage.Part(type: "input_audio", text: nil, audio: pcm.base64EncodedString()),
        ])))
    }

    /// Asks for nothing but a call to the named tool, as text, tagged with the review it answers.
    static func requestToolCall(named name: String, reviewID: String) throws -> String {
        try encode(TargetedResponse(response: .init(output_modalities: ["text"], tool_choice: .function(name), metadata: ["review": reviewID])))
    }

    /// Asks the tutor to speak, with tools off, tagged with the review it answers.
    static func requestSpeech(reviewID: String) throws -> String {
        try encode(TargetedResponse(response: .init(output_modalities: ["audio"], tool_choice: .none, metadata: ["review": reviewID])))
    }

    static func toolResult(callID: String, output: String) throws -> String {
        try encode(CreateItem(item: FunctionCallOutput(call_id: callID, output: output)))
    }

    static func cancelResponse() throws -> String { try encode(CancelResponse()) }

    /// Tells the server how much of the tutor's reply the learner actually heard before cutting in, so the
    /// conversation doesn't assume they heard the rest.
    static func truncate(itemID: String, contentIndex: Int, audioEndMs: Int) throws -> String {
        try encode(Truncate(item_id: itemID, content_index: contentIndex, audio_end_ms: audioEndMs))
    }
}

/// Server events the tutor reacts to; everything else on the socket is ignored.
nonisolated enum LiveTutorServerEvent: Equatable, Sendable {
    case sessionCreated
    case learnerStartedSpeaking(itemID: String)
    case learnerStoppedSpeaking
    case learnerTranscript(itemID: String, text: String)
    case learnerTranscriptUnavailable(itemID: String)
    /// `reviewID` is the `review` metadata the app attached when it asked for the response.
    case responseCreated(responseID: String, reviewID: String?)
    case toolCall(responseID: String, callID: String, name: String, arguments: String)
    case tutorAudio(responseID: String, itemID: String, contentIndex: Int, pcm: Data)
    case tutorTranscript(itemID: String, delta: String)
    case responseDone(responseID: String)
    case failed(code: String?, message: String)

    private struct Raw: Decodable {
        struct Failure: Decodable {
            let message: String
            let code: String?
        }

        struct Response: Decodable {
            let id: String
            let metadata: [String: String]?
        }

        let type: String
        let itemID: String?
        let contentIndex: Int?
        let responseID: String?
        let callID: String?
        let name: String?
        let arguments: String?
        let delta: String?
        let transcript: String?
        let response: Response?
        let error: Failure?

        enum CodingKeys: String, CodingKey {
            case type, delta, transcript, error, name, arguments, response
            case itemID = "item_id"
            case contentIndex = "content_index"
            case responseID = "response_id"
            case callID = "call_id"
        }
    }

    /// Decodes one frame, or returns nil for an event the tutor doesn't use. A used event missing a field it needs throws.
    private struct Kind: Decodable {
        let type: String
    }

    private static let handledTypes: Set<String> = [
        "session.created",
        "input_audio_buffer.speech_started",
        "input_audio_buffer.speech_stopped",
        "conversation.item.input_audio_transcription.completed",
        "conversation.item.input_audio_transcription.failed",
        "response.created",
        "response.function_call_arguments.done",
        "response.output_audio.delta",
        "response.output_audio_transcript.delta",
        "response.done",
        "error",
    ]

    static func decode(_ text: String) throws -> LiveTutorServerEvent? {
        let data = Data(text.utf8)
        // Only the events used here are read in full, so a field shaped differently elsewhere can't break the socket.
        guard handledTypes.contains(try JSONDecoder().decode(Kind.self, from: data).type) else { return nil }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        func required<Value>(_ value: Value?, _ field: String) throws -> Value {
            guard let value else {
                throw CoachError.invalidResponse(operation: "Listening to your tutor", reason: "\(raw.type) had no \(field)")
            }
            return value
        }
        switch raw.type {
        case "session.created":
            return .sessionCreated
        case "input_audio_buffer.speech_started":
            return .learnerStartedSpeaking(itemID: try required(raw.itemID, "item_id"))
        case "input_audio_buffer.speech_stopped":
            return .learnerStoppedSpeaking
        case "conversation.item.input_audio_transcription.completed":
            return .learnerTranscript(itemID: try required(raw.itemID, "item_id"), text: try required(raw.transcript, "transcript"))
        case "conversation.item.input_audio_transcription.failed":
            return .learnerTranscriptUnavailable(itemID: try required(raw.itemID, "item_id"))
        case "response.output_audio.delta":
            guard let pcm = Data(base64Encoded: try required(raw.delta, "delta")) else {
                throw CoachError.invalidResponse(operation: "Listening to your tutor", reason: "the tutor's audio wasn't Base64")
            }
            return .tutorAudio(
                responseID: try required(raw.responseID, "response_id"),
                itemID: try required(raw.itemID, "item_id"),
                contentIndex: try required(raw.contentIndex, "content_index"),
                pcm: pcm
            )
        case "response.output_audio_transcript.delta":
            return .tutorTranscript(itemID: try required(raw.itemID, "item_id"), delta: try required(raw.delta, "delta"))
        case "response.created":
            let response = try required(raw.response, "response")
            return .responseCreated(responseID: response.id, reviewID: response.metadata?["review"])
        case "response.function_call_arguments.done":
            return .toolCall(
                responseID: try required(raw.responseID, "response_id"),
                callID: try required(raw.callID, "call_id"),
                name: try required(raw.name, "name"),
                arguments: try required(raw.arguments, "arguments")
            )
        case "response.done":
            return .responseDone(responseID: try required(raw.response, "response").id)
        case "error":
            let failure = try required(raw.error, "error")
            return .failed(code: failure.code, message: failure.message)
        default:
            return nil
        }
    }
}

/// What each side said, in the order they spoke. Lines are keyed by the server's conversation item.
nonisolated struct LiveTutorTranscript: Equatable, Sendable {
    struct Line: Identifiable, Equatable, Sendable {
        enum Speaker: Equatable, Sendable { case tutor, learner }

        let id: String
        let speaker: Speaker
        /// Empty while the learner's words are still being transcribed.
        let text: String
    }

    let lines: [Line]

    static let empty = LiveTutorTranscript(lines: [])

    /// The learner's line is placed when they start speaking, because their transcript arrives after the tutor
    /// has already started answering.
    func applying(_ event: LiveTutorServerEvent) -> LiveTutorTranscript {
        switch event {
        case .learnerStartedSpeaking(let itemID):
            guard !lines.contains(where: { $0.id == itemID }) else { return self }
            return LiveTutorTranscript(lines: lines + [Line(id: itemID, speaker: .learner, text: "")])
        case .learnerTranscript(let itemID, let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return removing(itemID) }
            guard lines.contains(where: { $0.id == itemID }) else {
                return LiveTutorTranscript(lines: lines + [Line(id: itemID, speaker: .learner, text: trimmed)])
            }
            return LiveTutorTranscript(lines: lines.map { $0.id == itemID ? Line(id: itemID, speaker: .learner, text: trimmed) : $0 })
        case .learnerTranscriptUnavailable(let itemID):
            return removing(itemID)
        case .tutorTranscript(let itemID, let delta):
            guard lines.contains(where: { $0.id == itemID }) else {
                return LiveTutorTranscript(lines: lines + [Line(id: itemID, speaker: .tutor, text: delta)])
            }
            return LiveTutorTranscript(lines: lines.map { $0.id == itemID ? Line(id: itemID, speaker: .tutor, text: $0.text + delta) : $0 })
        case .sessionCreated, .learnerStoppedSpeaking, .responseCreated, .toolCall, .tutorAudio, .responseDone, .failed:
            return self
        }
    }

    private func removing(_ itemID: String) -> LiveTutorTranscript {
        LiveTutorTranscript(lines: lines.filter { $0.id != itemID })
    }
}

/// When the tutor's queued voice will finish, and how much of the reply now playing has been heard. Times are
/// offsets from the start of the call; audio is assumed to play back to back as it arrives.
nonisolated struct TutorPlaybackTimeline: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        let id: String
        let contentIndex: Int
        let startsAt: Duration
    }

    /// When everything scheduled so far will have played.
    let endsAt: Duration
    /// The reply whose audio was scheduled last.
    let current: Item?

    static let idle = TutorPlaybackTimeline(endsAt: .zero, current: nil)

    func scheduling(itemID: String, contentIndex: Int, frames: Int, at now: Duration) -> TutorPlaybackTimeline {
        let start = max(now, endsAt)
        let length = Duration.seconds(Double(frames) / LiveTutorRealtime.sampleRate)
        let isSameItem = current?.id == itemID && current?.contentIndex == contentIndex
        let item = isSameItem ? current : Item(id: itemID, contentIndex: contentIndex, startsAt: start)
        return TutorPlaybackTimeline(endsAt: start + length, current: item)
    }

    func remaining(at now: Duration) -> Duration {
        max(.zero, endsAt - now)
    }

    /// How many milliseconds of the current reply have played, or nil when nothing is playing.
    func heardMilliseconds(at now: Duration) -> Int? {
        guard let current, now < endsAt else { return nil }
        let heard = max(.zero, now - current.startsAt)
        return Int(heard / .milliseconds(1))
    }
}
