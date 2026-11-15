import Foundation

/// What the app sends for one attempt. The backend resolves the reference text and target window from stored project data
/// and takes the user from the session, so the client supplies identifiers and audio only, never scores or reference text.
nonisolated struct AssessmentRequest: Equatable, Sendable {
    var attemptId: String
    var lineId: String
    var referenceVersion: Int
    /// The line's speech locale, such as en-US.
    var locale: String
    var recordedAt: Date
    /// The 16 kHz mono WAV made from the original take by `AssessmentAudioEncoder`.
    var recording: EncodedRecording
}

/// The backend transport conforms to this. It reports queued and processing as they happen and ends with exactly one terminal state.
/// Cancelling the consuming task cancels the job; cancellation ends the stream without a terminal state.
nonisolated protocol PronunciationAssessing: Sendable {
    func assess(_ request: AssessmentRequest) -> AsyncStream<AssessmentState>
}

/// Used whenever no backend is configured: it reports that honestly and never produces a score.
nonisolated struct UnavailableAssessmentService: PronunciationAssessing {
    func assess(_ request: AssessmentRequest) -> AsyncStream<AssessmentState> {
        AsyncStream { continuation in
            continuation.yield(.unavailable(.notConfigured))
            continuation.finish()
        }
    }
}
