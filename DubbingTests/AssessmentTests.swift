import AVFoundation
import Foundation
import Testing
@testable import Dubbing

/// SYNTHETIC contract JSON and generated tones; no provider produced these and no real recording is involved.
struct AssessmentContractTests {
    private static let scoredJSON = #"""
    {
      "schemaVersion": 1, "rubricVersion": "language-v1", "assessmentId": "assessment_001", "attemptId": "take_003",
      "lineId": "scene_001_line_02", "referenceVersion": 1, "locale": "en-US", "recordedAt": "2026-11-14T18:00:00-08:00",
      "status": "scored", "referenceText": "You underestimate my power.", "recognizedText": "You underestimate power.",
      "scores": {"languageOverall": 80, "pronunciation": 82, "wordAccuracy": 75, "fluency": 80, "timingFit": 90},
      "unavailableMetrics": [],
      "wordResults": [
        {"referenceWordIndex": 0, "expected": "You", "recognized": "You", "textStatus": "matched", "pronunciationScore": 96, "startMs": 200, "endMs": 420},
        {"referenceWordIndex": 1, "expected": "underestimate", "recognized": "underestimate", "textStatus": "matched", "pronunciationScore": 64, "startMs": 430, "endMs": 1550},
        {"referenceWordIndex": 2, "expected": "my", "recognized": null, "textStatus": "omitted", "pronunciationScore": null, "pronunciationUnavailableReason": "omitted_word", "startMs": null, "endMs": null},
        {"referenceWordIndex": 3, "expected": "power", "recognized": "power", "textStatus": "matched", "pronunciationScore": 91, "startMs": 2000, "endMs": 2900}
      ],
      "coaching": {"summary": "You skipped 'my'.", "strengths": [], "focus": [{"kind": "word_accuracy", "referenceWordIndex": 2, "instruction": "Say 'my' before 'power'.", "practiceText": "my power"}]}
    }
    """#

    private static let unscorableJSON = #"""
    {
      "schemaVersion": 1, "rubricVersion": "language-v1", "assessmentId": "assessment_002", "attemptId": "take_004",
      "lineId": "scene_001_line_02", "referenceVersion": 1, "locale": "en-US", "recordedAt": "2026-11-14T18:00:00.250Z",
      "status": "unscorable", "reason": "no_speech", "referenceText": "You underestimate my power.", "recognizedText": null,
      "scores": null, "unavailableMetrics": [], "wordResults": [],
      "coaching": {"summary": "We couldn't hear speech. Move closer and try again.", "strengths": [], "focus": []}
    }
    """#

    private func edited(_ json: String, _ transform: (inout [String: Any]) -> Void) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        transform(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func issues(_ data: Data, recordingDurationMs: Int? = nil) throws -> [String] {
        do {
            _ = try AssessmentContract.decode(data, recordingDurationMs: recordingDurationMs)
            return []
        } catch let error as AssessmentValidationError {
            return error.issues
        }
    }

    @Test func decodesAScoredResponseIncludingNullsAndOmissions() throws {
        let response = try AssessmentContract.decode(Data(Self.scoredJSON.utf8), recordingDurationMs: 3_200)
        #expect(response.status == .scored)
        #expect(response.scores?.pronunciation == 82)
        #expect(response.wordResults[2].textStatus == .omitted)
        #expect(response.wordResults[2].pronunciationScore == nil)
        #expect(response.wordResults[2].pronunciationUnavailableReason == .omittedWord)
        #expect(response.wordResults[1].pronunciationScore == 64)
    }

    @Test func decodesAnUnscorableResponseWithoutScores() throws {
        let response = try AssessmentContract.decode(Data(Self.unscorableJSON.utf8))
        #expect(response.status == .unscorable)
        #expect(response.reason == .noSpeech)
        #expect(response.scores == nil)
        #expect(response.recognizedText == nil)
    }

    @Test func encodingKeepsRequiredNullsSoTheResponseRoundTrips() throws {
        let response = try AssessmentContract.decode(Data(Self.unscorableJSON.utf8))
        let again = try JSONDecoder().decode(AssessmentResponse.self, from: JSONEncoder().encode(response))
        #expect(again == response)
    }

    @Test func aMissingRequiredKeyIsADecodeFailureNotADefault() throws {
        let data = try edited(Self.unscorableJSON) { $0.removeValue(forKey: "recognizedText") }
        #expect(throws: DecodingError.self) { try AssessmentContract.decode(data) }
        let unknownReason = try edited(Self.unscorableJSON) { $0["reason"] = "silence" }
        #expect(throws: DecodingError.self) { try AssessmentContract.decode(unknownReason) }
    }

    @Test func rejectsNullScoresWithoutAnExplanation() throws {
        let data = try edited(Self.scoredJSON) {
            var scores = $0["scores"] as? [String: Any] ?? [:]
            scores["fluency"] = NSNull()
            $0["scores"] = scores
        }
        let found = try issues(data)
        #expect(found.contains("scores.languageOverall must be null when a component is missing"))
        #expect(found.contains("unavailableMetrics must explain null metric fluency"))
    }

    @Test func rejectsWordAccuracyThatContradictsTheAlignment() throws {
        let data = try edited(Self.scoredJSON) {
            var scores = $0["scores"] as? [String: Any] ?? [:]
            scores["wordAccuracy"] = 100
            $0["scores"] = scores
        }
        #expect(try issues(data).contains("scores.wordAccuracy does not match the substitutions, omissions and insertions in wordResults"))
    }

    @Test func rejectsWordBoundariesOutsideTheRecordingAndBrokenOrdering() throws {
        #expect(try issues(Data(Self.scoredJSON.utf8), recordingDurationMs: 2_500).contains("wordResults[3]: endMs exceeds the recording duration"))

        let reordered = try edited(Self.scoredJSON) {
            var words = $0["wordResults"] as? [[String: Any]] ?? []
            words.swapAt(0, 1)
            $0["wordResults"] = words
        }
        #expect(try issues(reordered).contains { $0.contains("each reference token appears once, in order") })

        let reversed = try edited(Self.scoredJSON) {
            var words = $0["wordResults"] as? [[String: Any]] ?? []
            words[0]["startMs"] = 500
            words[0]["endMs"] = 400
            $0["wordResults"] = words
        }
        #expect(try issues(reversed).contains("wordResults[0]: boundaries must satisfy 0 <= startMs < endMs"))
    }

    @Test func rejectsAnUnscorableResponseThatCarriesScoresOrFocus() throws {
        let scored = try edited(Self.unscorableJSON) {
            $0["scores"] = ["languageOverall": 0, "pronunciation": 0, "wordAccuracy": 0, "fluency": 0, "timingFit": 0]
        }
        #expect(try issues(scored).contains("scores must be null when unscorable"))

        let focus = try edited(Self.unscorableJSON) {
            var coaching = $0["coaching"] as? [String: Any] ?? [:]
            coaching["strengths"] = ["Nice try."]
            $0["coaching"] = coaching
        }
        #expect(try issues(focus).contains("coaching must have empty strengths and focus when unscorable"))

        let badTime = try edited(Self.unscorableJSON) { $0["recordedAt"] = "yesterday" }
        #expect(try issues(badTime).contains("recordedAt must be an RFC 3339 timestamp"))
    }

    @Test func terminalStateTurnsMalformedResponsesIntoExplicitFailures() throws {
        #expect(AssessmentState.terminal(from: Data(Self.scoredJSON.utf8)).isTerminal)
        if case .scored(let response) = AssessmentState.terminal(from: Data(Self.scoredJSON.utf8)) {
            #expect(response.attemptId == "take_003")
        } else {
            Issue.record("expected a scored state")
        }
        if case .unscorable = AssessmentState.terminal(from: Data(Self.unscorableJSON.utf8)) {} else { Issue.record("expected an unscorable state") }

        let broken = try edited(Self.scoredJSON) { $0.removeValue(forKey: "scores") }
        guard case .failed(let failure) = AssessmentState.terminal(from: broken) else {
            Issue.record("expected a failed state")
            return
        }
        #expect(failure.kind == .invalidResponse)
        #expect(!failure.isRetryable)
        #expect(AssessmentFailure(kind: .providerUnavailable, message: "x").isRetryable)
        #expect(!AssessmentState.queued.isTerminal)
        #expect(!AssessmentState.processing.isTerminal)
    }

    @Test func theUnavailableServiceReportsNotConfiguredAndNothingElse() async {
        let request = AssessmentRequest(
            attemptId: "take_003", lineId: "line", referenceVersion: 1, locale: "en-US", recordedAt: Date(),
            recording: EncodedRecording(url: URL(fileURLWithPath: "/dev/null"), durationMs: 1, byteCount: 1)
        )
        var states: [AssessmentState] = []
        for await state in UnavailableAssessmentService().assess(request) { states.append(state) }
        #expect(states == [.unavailable(.notConfigured)])
    }
}

struct AssessmentAudioEncoderTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("assessment-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a synthetic sine tone as a PCM WAV so the encoder has a known source.
    private func writeTone(to url: URL, seconds: Double, sampleRate: Double, channels: AVAudioChannelCount) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let samples = try #require(buffer.floatChannelData?[channel])
            for frame in 0..<Int(frames) {
                samples[frame] = Float(0.4 * sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }

    private func littleEndian(_ data: Data, _ offset: Int, bytes: Int) -> Int {
        (0..<bytes).reduce(0) { $0 | Int(data[offset + $1]) << (8 * $1) }
    }

    @Test func convertsAStereo44kTakeToMono16kPCMWithoutTouchingTheOriginal() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("take.wav")
        try writeTone(to: source, seconds: 1.5, sampleRate: 44_100, channels: 2)
        let originalBytes = try Data(contentsOf: source)

        let destination = directory.appendingPathComponent("upload/take-16k.wav")
        let encoded = try AssessmentAudioEncoder.encode(from: source, to: destination)
        let wav = try Data(contentsOf: destination)

        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        #expect(littleEndian(wav, 20, bytes: 2) == 1)
        #expect(littleEndian(wav, 22, bytes: 2) == 1)
        #expect(littleEndian(wav, 24, bytes: 4) == 16_000)
        #expect(littleEndian(wav, 34, bytes: 2) == 16)
        let dataBytes = littleEndian(wav, 40, bytes: 4)
        #expect(dataBytes == wav.count - 44)
        #expect(abs(dataBytes / 2 - 24_000) <= 160)
        #expect(abs(encoded.durationMs - 1_500) <= 10)
        #expect(encoded.byteCount == wav.count)
        #expect(try Data(contentsOf: source) == originalBytes)

        let peak = stride(from: 44, to: wav.count - 1, by: 2).map { abs(Int(Int16(bitPattern: UInt16(wav[$0]) | UInt16(wav[$0 + 1]) << 8))) }.max() ?? 0
        #expect(peak > 5_000)
    }

    @Test func rejectsTakesOverTheAssessmentLimitInsteadOfTruncating() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("long.wav")
        try writeTone(to: source, seconds: 31, sampleRate: 8_000, channels: 1)
        let destination = directory.appendingPathComponent("out.wav")
        #expect(throws: AssessmentAudioError.tooLong(durationMs: 31_000, limitMs: 30_000)) {
            try AssessmentAudioEncoder.encode(from: source, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func rejectsUnreadableSourcesAndOverwritingTheOriginal() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing.wav")
        #expect(throws: AssessmentAudioError.self) {
            try AssessmentAudioEncoder.encode(from: missing, to: directory.appendingPathComponent("out.wav"))
        }
        let source = directory.appendingPathComponent("take.wav")
        try writeTone(to: source, seconds: 0.5, sampleRate: 16_000, channels: 1)
        #expect(throws: AssessmentAudioError.destinationIsSource) {
            try AssessmentAudioEncoder.encode(from: source, to: source)
        }
    }
}
