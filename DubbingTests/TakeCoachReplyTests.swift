import Foundation
import Testing
@testable import Dubbing

struct TakeCoachReplyTests {
    private actor RealtimeFixture: AvatarSocketTransport {
        nonisolated let receives: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        private var frames: [String]
        private var waiter: CheckedContinuation<String, any Error>?
        private(set) var sent: [String] = []
        private(set) var isClosed = false

        init(frames: [String]) {
            self.frames = frames
            (receives, continuation) = AsyncStream.makeStream()
        }

        func send(_ text: String) { sent.append(text) }

        func receive() async throws -> String {
            if isClosed { throw CancellationError() }
            if !frames.isEmpty { return frames.removeFirst() }
            return try await withCheckedThrowingContinuation {
                waiter = $0
                continuation.yield(())
            }
        }

        func close() {
            isClosed = true
            waiter?.resume(throwing: CancellationError())
            waiter = nil
            continuation.finish()
        }
    }

    @Test func reviewsTheCurrentTakeWithOneResponseAndNoSpeechRequest() async throws {
        let transport = RealtimeFixture(frames: [
            #"{"type":"response.created","response":{"id":"old","metadata":{"review":"previous-take"}}}"#,
            #"{"type":"response.done","response":{"id":"old","status":"completed"}}"#,
            #"{"type":"response.created","response":{"id":"current","metadata":{"review":"this-take"}}}"#,
            #"{"type":"response.function_call_arguments.done","response_id":"current","call_id":"suggestion","name":"suggest_next_step","arguments":"{\"suggestion\":\"retry\",\"tip\":\"Give the word power more room.\"}"}"#,
            #"{"type":"response.done","response":{"id":"current","status":"completed"}}"#,
        ])
        let pcm = Data([0, 1, 2, 3])
        let suggestion = try await TakeCoachReply.review(
            pcm: pcm, note: "The line: You underestimate my power.", reviewID: "this-take", on: transport, timeout: .seconds(1)
        )
        #expect(suggestion == TakeCoach.Suggestion(suggestion: .retry, tip: "Give the word power more room."))
        struct Frame: Decodable {
            struct Item: Decodable {
                struct Part: Decodable {
                    let audio: String?
                    let text: String?
                }
                let content: [Part]?
                let call_id: String?
            }
            let type: String
            let item: Item?
        }
        let sent = try await transport.sent.map { try JSONDecoder().decode(Frame.self, from: Data($0.utf8)) }
        #expect(sent.map(\.type) == ["conversation.item.create", "response.create", "conversation.item.create"])
        #expect(sent.first?.item?.content?.last?.audio == pcm.base64EncodedString())
        #expect(sent.first?.item?.content?.first?.text?.contains("You underestimate my power.") == true)
        #expect(sent.last?.item?.call_id == "suggestion")
        #expect(await !transport.isClosed)
        await transport.close()
    }

    @Test func anOpenAIFailureKeepsItsCause() async {
        let transport = RealtimeFixture(frames: [
            #"{"type":"response.created","response":{"id":"r","metadata":{"review":"take"}}}"#,
            #"{"type":"response.done","response":{"id":"r","status":"failed","status_details":{"error":{"code":"server_error","message":"Inference failed"}}}}"#,
        ])
        await #expect(throws: CoachError.providerFailed(operation: "Checking this line", message: "OpenAI response r was failed (server_error): Inference failed")) {
            try await TakeCoachReply.review(pcm: Data([0, 0]), note: "Synthetic line", reviewID: "take", on: transport, timeout: .seconds(1))
        }
        #expect(await transport.isClosed)
    }

    @Test func aMissingSuggestionFailsInsteadOfInventingATip() async {
        let transport = RealtimeFixture(frames: [
            #"{"type":"response.created","response":{"id":"r","metadata":{"review":"take"}}}"#,
            #"{"type":"response.done","response":{"id":"r","status":"completed"}}"#,
        ])
        await #expect(throws: CoachError.invalidResponse(operation: "Checking this line", reason: "your coach answered without a suggestion")) {
            try await TakeCoachReply.review(pcm: Data([0, 0]), note: "Synthetic line", reviewID: "take", on: transport, timeout: .seconds(1))
        }
        #expect(await transport.isClosed)
    }

    @Test func aStalledReviewClosesTheSocketAndReportsATimeout() async {
        let transport = RealtimeFixture(frames: [
            #"{"type":"response.created","response":{"id":"r","metadata":{"review":"take"}}}"#,
        ])
        await #expect(throws: CoachError.providerTimeout(operation: "Checking this line")) {
            try await TakeCoachReply.review(pcm: Data([0, 0]), note: "Synthetic line", reviewID: "take", on: transport, timeout: .milliseconds(20))
        }
        #expect(await transport.isClosed)
    }

    @Test func cancellingAReviewReleasesItsPendingReceive() async {
        let transport = RealtimeFixture(frames: [])
        let task = Task {
            try await TakeCoachReply.review(pcm: Data([0, 0]), note: "Synthetic line", reviewID: "take", on: transport, timeout: .seconds(8))
        }
        for await _ in transport.receives { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.isClosed)
    }
}
