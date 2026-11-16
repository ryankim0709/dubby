import Foundation

/// A single audio review: the tool's validated tip is the result, with no second speech-generation request.
nonisolated enum TakeCoachReply {
    private static let operation = "Checking this line"
    private static let toolName = "suggest_next_step"

    static func connect(on transport: any AvatarSocketTransport, timeout: Duration) async throws {
        try await withTimeout(on: transport, timeout: timeout) {
            while true {
                switch try LiveTutorServerEvent.decode(try await transport.receive()) {
                case .sessionCreated: return
                case .failed(_, let message):
                    throw CoachError.providerFailed(operation: operation, message: message)
                default: continue
                }
            }
        }
    }

    static func review(pcm: Data, note: String, reviewID: String, on transport: any AvatarSocketTransport, timeout: Duration) async throws -> TakeCoach.Suggestion {
        try await withTimeout(on: transport, timeout: timeout) {
            let instruction = "Review only this current recording against this line. Give one concrete tip in at most twelve words, quoting a word from the line. "
            try await transport.send(LiveTutorClientEvent.take(note: instruction + note, pcm: pcm))
            try await transport.send(LiveTutorClientEvent.requestToolCall(named: toolName, reviewID: reviewID))
            var responseID: String?
            var answer: (callID: String, suggestion: TakeCoach.Suggestion)?
            while true {
                switch try LiveTutorServerEvent.decode(try await transport.receive()) {
                case .responseCreated(let id, let tag) where tag == reviewID:
                    responseID = id
                case .toolCall(let id, let callID, let name, let arguments) where id == responseID && name == toolName:
                    let suggestion = try JSONDecoder().decode(TakeCoach.Suggestion.self, from: Data(arguments.utf8))
                    guard !suggestion.tip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw CoachError.invalidResponse(operation: operation, reason: "your coach's tip was empty")
                    }
                    answer = (callID, suggestion)
                case .responseDone(let id) where id == responseID:
                    guard let answer else {
                        throw CoachError.invalidResponse(operation: operation, reason: "your coach answered without a suggestion")
                    }
                    try await transport.send(LiveTutorClientEvent.toolResult(callID: answer.callID, output: "Shown to the learner."))
                    return answer.suggestion
                case .responseFailed(let id, let message) where id == responseID:
                    throw CoachError.providerFailed(operation: operation, message: message)
                case .failed(let code, let message):
                    guard code == "response_cancel_not_active" else {
                        throw CoachError.providerFailed(operation: operation, message: message)
                    }
                default: continue
                }
            }
        }
    }

    /// A cancelled receive can stay suspended until its WebSocket is closed.
    private static func withTimeout<Value: Sendable>(on transport: any AvatarSocketTransport, timeout: Duration, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw CoachError.providerTimeout(operation: Self.operation)
                }
                do {
                    guard let result = try await group.next() else { throw CancellationError() }
                    group.cancelAll()
                    return result
                } catch {
                    group.cancelAll()
                    await transport.close()
                    throw error
                }
            }
        } onCancel: {
            Task { await transport.close() }
        }
    }
}
