import Foundation
import os

/// The studio's take coach. After each take, the character listens to it through OpenAI's Realtime API,
/// suggests keeping it or trying again, and says why out loud. One session serves the whole studio visit, and
/// takes are reviewed one at a time; a newer take replaces an older one that hasn't been answered yet.
@MainActor
@Observable
final class TakeCoach {
    struct Suggestion: Equatable, Decodable {
        enum Action: String, Equatable, Decodable {
            case retry, keep
        }

        let suggestion: Action
        let tip: String
    }

    enum State: Equatable {
        case listening
        case suggested(Suggestion)
        case unavailable(String)
    }

    struct Review: Equatable {
        let takeID: UUID
        let state: State

        func failing(reason: String) -> Review {
            // Speech is optional once the learner has a valid AI suggestion.
            if case .suggested = state { return self }
            return Review(takeID: takeID, state: .unavailable(reason))
        }
    }

    private(set) var review: Review?
    private(set) var isSpeaking = false
    /// The character's talking face, when the dubbed character is one of the coaches. While it is live it says
    /// the tips; otherwise the phone plays them and the pop-up shows the hologram.
    private(set) var avatar: TakeCoachAvatar?

    private struct Request {
        let takeID: UUID
        let take: RecordedTake
        let note: String
    }

    private let backend: CoachBackendClient
    private let setup: DubSetup
    private let requests: AsyncStream<Request>
    private let requestContinuation: AsyncStream<Request>.Continuation
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private var transport: URLSessionSocketTransport?
    private var voice: TutorVoicePlayer?
    private var timeline = TutorPlaybackTimeline.idle
    private var settleTask: Task<Void, Never>?
    private var avatarTask: Task<Void, Never>?
    /// The take whose review the learner is still looking at; nil once they keep, retry, or leave.
    private var activeTakeID: UUID?
    /// The spoken response playing now, so the learner can cut it off.
    private var speakingResponseID: String?
    private var hasEnded = false

    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "take-coach")
    private static let operation = "Listening to your take"

    init(backend: CoachBackendClient, setup: DubSetup) {
        self.backend = backend
        self.setup = setup
        (requests, requestContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        startedAt = clock.now
    }

    /// Connects ahead of the first take, then reviews takes until the studio closes.
    func run() async {
        do {
            _ = try await connectedTransport()
        } catch {
            // The first take connects again and shows the failure on its card.
            Self.logger.warning("The take coach couldn't connect ahead of time. error=\(error.localizedDescription, privacy: .public)")
        }
        for await request in requests {
            guard !hasEnded else { return }
            do {
                try await review(request)
            } catch is CancellationError {
                return
            } catch {
                // Closing the studio closes the socket under a review in progress; that isn't a failure.
                guard !hasEnded else { return }
                Self.logger.warning("A take review failed. error=\(error.localizedDescription, privacy: .public)")
                if activeTakeID == request.takeID {
                    review = review?.failing(reason: error.localizedDescription)
                }
                stopSpeaking()
                voice?.shutDown()
                voice = nil
                // A broken session is replaced on the next take.
                await transport?.close()
                transport = nil
            }
        }
    }

    /// Starts reviewing a new take. `note` is what the phone measured about it.
    func listen(to takeID: UUID, take: RecordedTake, note: String) {
        guard !hasEnded else { return }
        stopSpeaking()
        activeTakeID = takeID
        review = Review(takeID: takeID, state: .listening)
        requestContinuation.yield(Request(takeID: takeID, take: take, note: note))
    }

    /// The learner acted on the take, so anything still coming about it is no longer wanted.
    func dismiss() {
        stopSpeaking()
        activeTakeID = nil
    }

    func end() async {
        guard !hasEnded else { return }
        hasEnded = true
        dismiss()
        requestContinuation.finish()
        voice?.shutDown()
        avatarTask?.cancel()
        await avatar?.end()
        await transport?.close()
        transport = nil
    }

    /// Silences the coach, for when the learner plays their take, without dropping the review.
    func stopSpeaking() {
        settleTask?.cancel()
        voice?.stop()
        avatar?.interrupt()
        timeline = .idle
        isSpeaking = false
        guard speakingResponseID != nil, let transport else { return }
        speakingResponseID = nil
        Task {
            do {
                try await transport.send(LiveTutorClientEvent.cancelResponse())
            } catch {
                Self.logger.warning("Cancelling the coach's reply failed. error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func connectedTransport() async throws -> URLSessionSocketTransport {
        if let transport { return transport }
        let lines = setup.script.lines(spokenBy: setup.characterID)
        let pitchHz = try await Self.referencePitch(setup: setup, lines: lines)
        let grant = try await backend.takeCoachSession(
            sceneTitle: setup.clip.title,
            characterName: setup.script.speaker(withID: setup.characterID)?.name ?? "Your coach",
            locale: setup.locale,
            characterLines: lines.prefix(12).map { String($0.text.prefix(1_000)) },
            referencePitchHz: pitchHz
        )
        startAvatar(for: grant)
        let transport = URLSessionSocketTransport(
            url: try LiveTutorRealtime.socketURL(model: grant.model),
            protocols: LiveTutorRealtime.subprotocols(clientSecret: grant.clientSecret)
        )
        while true {
            switch try LiveTutorServerEvent.decode(try await transport.receive()) {
            case .sessionCreated:
                guard !hasEnded else {
                    await transport.close()
                    throw CancellationError()
                }
                self.transport = transport
                return transport
            case .failed(_, let message):
                await transport.close()
                throw CoachError.providerFailed(operation: Self.operation, message: message)
            default:
                continue
            }
        }
    }

    /// Starts the avatar once per visit, so a replaced Realtime session keeps the same face.
    private func startAvatar(for grant: LiveTutorGrant) {
        guard avatar == nil, !hasEnded, let characterID = grant.avatarCharacterId else { return }
        // LITE sessions ignore the language; the token route only takes one for the coach screen's sake.
        let language = SpokenLanguage.all.first { $0.identifier == setup.locale } ?? SpokenLanguage.all[0]
        let avatar = TakeCoachAvatar(backend: backend, characterID: characterID, language: language)
        self.avatar = avatar
        avatarTask = Task { await avatar.run() }
    }

    private func review(_ request: Request) async throws {
        let pcm = try await Self.realtimePCM(of: request.take.url)
        let transport = try await connectedTransport()
        let reviewID = request.takeID.uuidString
        try await transport.send(LiveTutorClientEvent.take(note: request.note, pcm: pcm))
        try await transport.send(LiveTutorClientEvent.requestToolCall(named: Self.toolName, reviewID: reviewID))
        let (callID, suggestion) = try await awaitSuggestion(on: transport, reviewID: reviewID)
        // The call needs its result in the conversation either way, or the next turn starts from a dangling call.
        guard activeTakeID == request.takeID else {
            try await transport.send(LiveTutorClientEvent.toolResult(callID: callID, output: "The learner moved on before seeing this."))
            return
        }
        review = Review(takeID: request.takeID, state: .suggested(suggestion))
        try await transport.send(LiveTutorClientEvent.toolResult(callID: callID, output: "Shown to the learner."))
        try await transport.send(LiveTutorClientEvent.requestSpeech(reviewID: reviewID))
        try await speak(on: transport, takeID: request.takeID, reviewID: reviewID)
    }

    /// Reads events until the tagged response ends, keeping its call to the suggestion tool.
    private func awaitSuggestion(on transport: URLSessionSocketTransport, reviewID: String) async throws -> (String, Suggestion) {
        var responseID: String?
        var answer: (String, Suggestion)?
        while true {
            switch try LiveTutorServerEvent.decode(try await transport.receive()) {
            case .responseCreated(let id, let tag) where tag == reviewID:
                responseID = id
            case .toolCall(let id, let callID, let name, let arguments) where id == responseID && name == Self.toolName:
                answer = (callID, try Self.decodeSuggestion(arguments))
            case .responseDone(let id) where id == responseID:
                guard let answer else {
                    throw CoachError.invalidResponse(operation: Self.operation, reason: "your coach answered without a suggestion")
                }
                return answer
            case .failed(let code, let message):
                try Self.throwUnlessHarmless(code: code, message: message)
            default:
                continue
            }
        }
    }

    /// Plays the tagged spoken response as it arrives, unless the learner has moved on. A live avatar instead gets
    /// the whole response once it has arrived, because it lip-syncs one sealed utterance at a time.
    private func speak(on transport: URLSessionSocketTransport, takeID: UUID, reviewID: String) async throws {
        var responseID: String?
        let avatar = avatar.flatMap { $0.isLive ? $0 : nil }
        var avatarPCM = Data()
        while true {
            switch try LiveTutorServerEvent.decode(try await transport.receive()) {
            case .responseCreated(let id, let tag) where tag == reviewID:
                responseID = id
                if activeTakeID == takeID { speakingResponseID = id }
            case .tutorAudio(let id, let itemID, let contentIndex, let pcm) where id == responseID && activeTakeID == takeID:
                guard avatar == nil else {
                    avatarPCM.append(pcm)
                    continue
                }
                let samples = LiveTutorRealtime.samples(fromPCM16: pcm)
                if voice == nil { voice = try TutorVoicePlayer() }
                try voice?.play(samples)
                timeline = timeline.scheduling(itemID: itemID, contentIndex: contentIndex, frames: samples.count, at: clock.now - startedAt)
                settleTask?.cancel()
                isSpeaking = true
            case .responseDone(let id) where id == responseID:
                // Stopping the coach clears the speaking response, so a reply cut off while arriving isn't said later.
                if let avatar, speakingResponseID == id, !avatarPCM.isEmpty {
                    avatar.speak(pcm: avatarPCM)
                }
                if speakingResponseID == id { speakingResponseID = nil }
                settleAfterPlayback()
                return
            case .failed(let code, let message):
                try Self.throwUnlessHarmless(code: code, message: message)
            default:
                continue
            }
        }
    }

    /// The reply finishes arriving before it finishes playing, so the hologram keeps talking until then.
    private func settleAfterPlayback() {
        let remaining = timeline.remaining(at: clock.now - startedAt)
        settleTask?.cancel()
        settleTask = Task {
            do {
                try await clock.sleep(for: remaining)
            } catch {
                return
            }
            isSpeaking = false
        }
    }

    private static let toolName = "suggest_next_step"

    private static func decodeSuggestion(_ arguments: String) throws -> Suggestion {
        let suggestion: Suggestion
        do {
            suggestion = try JSONDecoder().decode(Suggestion.self, from: Data(arguments.utf8))
        } catch {
            throw CoachError.invalidResponse(operation: operation, reason: "your coach's suggestion couldn't be read")
        }
        guard !suggestion.tip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoachError.invalidResponse(operation: operation, reason: "your coach's tip was empty")
        }
        return suggestion
    }

    /// Cancelling a reply that had already finished is reported as an error but changes nothing.
    private static func throwUnlessHarmless(code: String?, message: String) throws {
        guard code != "response_cancel_not_active" else { return }
        throw CoachError.providerFailed(operation: operation, message: message)
    }

    @concurrent
    private static func referencePitch(setup: DubSetup, lines: [ScriptLine]) async throws -> Double? {
        let url = setup.clip.workingDirectory.appending(path: "coach-reference.m4a")
        try await MediaPipeline.exportAudio(from: setup.clip.url, section: setup.section, to: url)
        let audio = try MediaPipeline.readMonoAudio(from: url)
        let pitches = lines.prefix(3).compactMap { line -> Double? in
            let lower = min(audio.samples.count, max(0, Int(line.start * audio.sampleRate)))
            let upper = min(audio.samples.count, max(lower, Int(min(line.end, line.start + 1) * audio.sampleRate)))
            return VoicePrint.pitchHz(samples: Array(audio.samples[lower..<upper]), sampleRate: audio.sampleRate)
        }.sorted()
        return pitches.isEmpty ? nil : pitches[pitches.count / 2]
    }

    @concurrent
    private static func realtimePCM(of url: URL) async throws -> Data {
        let audio = try MediaPipeline.readMonoAudio(from: url)
        return try LiveTutorMicrophoneEncoder(inputSampleRate: audio.sampleRate).encode(audio.samples)
    }
}
