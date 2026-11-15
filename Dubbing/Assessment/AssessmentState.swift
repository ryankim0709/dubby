import Foundation

/// Why no assessment can run at all. The app shows this honestly instead of a placeholder score.
nonisolated enum AssessmentUnavailability: Equatable, Sendable {
    /// No assessment backend is configured for this build.
    case notConfigured
    /// The take came from a QA audio fixture rather than the microphone, so no acoustic assessment of it would mean anything.
    case syntheticInput
}

/// A failed assessment job. These are never shown as unscorable audio or as a low score; the original recording is kept so the learner can retry.
nonisolated struct AssessmentFailure: Error, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case invalidInput = "invalid_input"
        case invalidReference = "invalid_reference"
        case providerUnavailable = "provider_unavailable"
        case providerAuth = "provider_auth"
        case providerRejected = "provider_rejected"
        case invalidProviderResponse = "invalid_provider_response"
        /// The app could not reach the backend or upload the recording.
        case transport
        /// The backend answered with a response that failed decoding or contract validation.
        case invalidResponse = "invalid_response"
    }

    let kind: Kind
    /// A short explanation safe to show or log: never a transcript, token or recording.
    let message: String

    /// Whether trying the same recording again can succeed without any change.
    var isRetryable: Bool { kind == .providerUnavailable || kind == .transport }
}

/// What an assessment job is doing, from the learner's point of view.
nonisolated enum AssessmentState: Equatable, Sendable {
    case unavailable(AssessmentUnavailability)
    case queued
    case processing
    case scored(AssessmentResponse)
    case unscorable(AssessmentResponse)
    case failed(AssessmentFailure)

    var isTerminal: Bool {
        switch self {
        case .unavailable, .scored, .unscorable, .failed: true
        case .queued, .processing: false
        }
    }

    /// Decodes and validates backend JSON into a terminal state, so a malformed response becomes an explicit failure rather than a score.
    static func terminal(from data: Data, recordingDurationMs: Int? = nil) -> AssessmentState {
        do {
            let response = try AssessmentContract.decode(data, recordingDurationMs: recordingDurationMs)
            return response.status == .scored ? .scored(response) : .unscorable(response)
        } catch let error as AssessmentValidationError {
            return .failed(AssessmentFailure(kind: .invalidResponse, message: error.localizedDescription))
        } catch {
            return .failed(AssessmentFailure(kind: .invalidResponse, message: "The assessment response could not be decoded: \(error.localizedDescription)"))
        }
    }
}
