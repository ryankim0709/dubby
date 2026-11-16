import Foundation
import os

/// Reviews the current recorded line over one warm Realtime connection and returns a single written tip.
@MainActor
@Observable
final class TakeCoach {
    nonisolated struct Suggestion: Equatable, Decodable, Sendable {
        enum Action: String, Equatable, Decodable, Sendable {
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
            if case .suggested = state { return self }
            return Review(takeID: takeID, state: .unavailable(reason))
        }
    }

    private struct Request {
        let takeID: UUID
        let take: RecordedTake
        let note: String
    }

    private(set) var review: Review?
    private let backend: CoachBackendClient
    private let setup: DubSetup
    private let requests: AsyncStream<Request>
    private let requestContinuation: AsyncStream<Request>.Continuation
    private var transport: URLSessionSocketTransport?
    private var reviewTask: Task<Void, any Error>?
    private var activeTakeID: UUID?
    private var hasEnded = false

    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "take-coach")

    init(backend: CoachBackendClient, setup: DubSetup) {
        self.backend = backend
        self.setup = setup
        (requests, requestContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func run() async {
        await withTaskCancellationHandler {
            await reviewRequests()
        } onCancel: {
            Task { await self.end() }
        }
    }

    private func reviewRequests() async {
        do {
            _ = try await connectedTransport()
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning("The take coach couldn't connect ahead of time. error=\(error.localizedDescription, privacy: .public)")
        }
        for await request in requests {
            guard !hasEnded else { return }
            guard activeTakeID == request.takeID else { continue }
            let task = Task { try await self.review(request) }
            reviewTask = task
            do {
                try await task.value
            } catch is CancellationError {
                await disconnect()
                if hasEnded || Task.isCancelled { return }
            } catch {
                guard !hasEnded else { return }
                Self.logger.warning("A take review failed. error=\(error.localizedDescription, privacy: .public)")
                if activeTakeID == request.takeID {
                    review = review?.failing(reason: error.localizedDescription)
                }
                await disconnect()
            }
            reviewTask = nil
        }
    }

    func listen(to takeID: UUID, take: RecordedTake, note: String) {
        guard !hasEnded else { return }
        reviewTask?.cancel()
        activeTakeID = takeID
        review = Review(takeID: takeID, state: .listening)
        requestContinuation.yield(Request(takeID: takeID, take: take, note: note))
    }

    func dismiss() {
        activeTakeID = nil
        reviewTask?.cancel()
    }

    func end() async {
        guard !hasEnded else { return }
        hasEnded = true
        dismiss()
        requestContinuation.finish()
        await disconnect()
    }

    private func disconnect() async {
        await transport?.close()
        transport = nil
    }

    private func connectedTransport() async throws -> URLSessionSocketTransport {
        if let transport { return transport }
        let grant = try await backend.takeCoachSession(
            sceneTitle: setup.clip.title,
            characterName: setup.script.speaker(withID: setup.characterID)?.name ?? "Your coach",
            locale: setup.locale,
            characterLines: setup.script.lines(spokenBy: setup.characterID).prefix(12).map { String($0.text.prefix(1_000)) },
            referencePitchHz: nil
        )
        try Task.checkCancellation()
        guard !hasEnded else { throw CancellationError() }
        let transport = URLSessionSocketTransport(
            url: try LiveTutorRealtime.socketURL(model: grant.model),
            protocols: LiveTutorRealtime.subprotocols(clientSecret: grant.clientSecret)
        )
        self.transport = transport
        do {
            try await TakeCoachReply.connect(on: transport, timeout: .seconds(8))
        } catch {
            await disconnect()
            throw error
        }
        return transport
    }

    private func review(_ request: Request) async throws {
        let pcm = try await Self.realtimePCM(of: request.take.url)
        let transport = try await connectedTransport()
        let suggestion = try await TakeCoachReply.review(
            pcm: pcm, note: request.note, reviewID: request.takeID.uuidString,
            on: transport, timeout: .seconds(8)
        )
        guard activeTakeID == request.takeID else { return }
        review = Review(takeID: request.takeID, state: .suggested(suggestion))
    }

    @concurrent
    private static func realtimePCM(of url: URL) async throws -> Data {
        let audio = try MediaPipeline.readMonoAudio(from: url)
        return try LiveTutorMicrophoneEncoder(inputSampleRate: audio.sampleRate).encode(audio.samples)
    }
}
