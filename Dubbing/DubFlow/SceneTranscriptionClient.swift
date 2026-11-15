import CryptoKit
import Foundation

nonisolated enum SceneTranscriptionError: LocalizedError, Equatable {
    case backendNotConfigured
    case invalidResponse(String)
    case stillProcessing

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            "Library transcription needs a backend connection in this build. Use an iPhone for on-device transcription."
        case .invalidResponse(let reason):
            "The scene transcript couldn't be used: \(reason)."
        case .stillProcessing:
            "The library scene is still being transcribed. Try again shortly."
        }
    }
}

/// Word timings belong to the full published video; the studio uses seconds relative to its selected section.
nonisolated struct SceneTranscript: Decodable, Sendable {
    let locale: String
    let durationSeconds: Double
    let words: [TranscribedWord]

    func words(for request: TranscriptionRequest) throws -> [TranscribedWord] {
        guard locale == request.language.identifier else {
            throw SceneTranscriptionError.invalidResponse("the transcript's language doesn't match the selected language")
        }
        guard durationSeconds.isFinite, durationSeconds > 0, abs(durationSeconds - request.clip.durationSeconds) < 1 else {
            throw SceneTranscriptionError.invalidResponse("the transcript's duration doesn't match the video")
        }
        let section = request.section
        guard section.start.isFinite, section.end.isFinite, section.start >= 0, section.end > section.start, section.end <= request.clip.durationSeconds else {
            throw SceneTranscriptionError.invalidResponse("the selected section is outside the video")
        }
        var previousStart = 0.0
        for word in words {
            guard !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  word.start.isFinite, word.end.isFinite, word.start >= previousStart,
                  word.end >= word.start, word.end <= durationSeconds + 0.1 else {
                throw SceneTranscriptionError.invalidResponse("word timings are missing, out of order, or outside the video")
            }
            previousStart = word.start
        }
        return try wordsWithMeasuredSpans().compactMap { word in
            let start = max(word.start, section.start)
            let end = min(word.end, section.end)
            guard end > start else { return nil }
            return TranscribedWord(text: word.text, start: start - section.start, end: end - section.start)
        }
    }

    private func wordsWithMeasuredSpans() throws -> [TranscribedWord] {
        var timed: [TranscribedWord] = []
        var pending: [String] = []
        for word in words {
            if word.end == word.start {
                pending.append(word.text)
            } else {
                // A provider can give a token no duration; keep its text with the next measured span.
                timed.append(TranscribedWord(text: (pending + [word.text]).joined(separator: " "), start: word.start, end: word.end))
                pending = []
            }
        }
        if !pending.isEmpty {
            guard let last = timed.popLast() else {
                throw SceneTranscriptionError.invalidResponse("the recognized words have no measured duration")
            }
            timed.append(TranscribedWord(text: ([last.text] + pending).joined(separator: " "), start: last.start, end: last.end))
        }
        return timed
    }
}

/// Retrieves shared transcripts of published scenes, without sending learner recordings or provider keys.
nonisolated struct SceneTranscriptionClient: Sendable {
    let baseURL: URL

    private enum Reply: Decodable {
        case processing
        case ready(SceneTranscript)

        private enum CodingKeys: String, CodingKey { case status }
        private enum Status: String, Decodable { case processing, ready }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Status.self, forKey: .status) {
            case .processing: self = .processing
            case .ready: self = .ready(try SceneTranscript(from: decoder))
            }
        }
    }

    static func configured(in bundle: Bundle) throws -> SceneTranscriptionClient {
        guard let baseURL = CoachBackendClient.configuredBaseURL(in: bundle) else {
            throw SceneTranscriptionError.backendNotConfigured
        }
        return SceneTranscriptionClient(baseURL: baseURL)
    }

    @concurrent
    func transcribe(_ request: TranscriptionRequest) async throws -> [TranscribedWord] {
        struct Body: Encodable { let slug: String; let sha256: String; let locale: String }
        let video = try Data(contentsOf: request.clip.url, options: .mappedIfSafe)
        let body = Body(
            slug: request.clip.url.deletingPathExtension().lastPathComponent,
            sha256: Data(SHA256.hash(data: video)).base64EncodedString(),
            locale: request.language.identifier
        )
        var urlRequest = try ServiceRequest.json(method: "POST", url: baseURL.appending(path: "scenes/transcribe"), body: body, headers: [:])
        urlRequest.timeoutInterval = 110
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(125))
        while clock.now < deadline {
            try Task.checkCancellation()
            let operation = "Transcribing the library scene"
            let data = try await ServiceRequest.data(for: urlRequest, operation: operation)
            switch try ServiceRequest.decode(Reply.self, from: data, operation: operation) {
            case .ready(let transcript): return try transcript.words(for: request)
            case .processing: try await Task.sleep(for: .seconds(2))
            }
        }
        throw SceneTranscriptionError.stillProcessing
    }
}
