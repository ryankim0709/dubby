import Foundation
import Testing
@testable import Dubbing

struct SceneTranscriptionTests {
    private let request = TranscriptionRequest(
        clip: ImportedClip(url: URL(filePath: "/synthetic-scene.mp4"), title: "Synthetic scene", durationSeconds: 10, workingDirectory: URL(filePath: "/work")),
        section: ClipSection(start: 4, end: 7),
        language: SpokenLanguage(identifier: "en-US", name: "English")
    )

    @Test func selectedWordsUseSectionRelativeTimingsAndStayInsideItsBounds() throws {
        let transcript = SceneTranscript(locale: "en-US", durationSeconds: 10, words: [
            TranscribedWord(text: "Before.", start: 1, end: 2),
            TranscribedWord(text: "First", start: 3.8, end: 4.5),
            TranscribedWord(text: "sentence.", start: 4.5, end: 5.25),
            TranscribedWord(text: "Last.", start: 6.5, end: 7.2),
            TranscribedWord(text: "After.", start: 8, end: 9),
        ])
        let words = try transcript.words(for: request)
        #expect(words == [
            TranscribedWord(text: "First", start: 0, end: 0.5),
            TranscribedWord(text: "sentence.", start: 0.5, end: 1.25),
            TranscribedWord(text: "Last.", start: 2.5, end: 3),
        ])
        let lines = ScriptBuilder.segmentLines(words: words, pauseThreshold: 0.7, sentencePause: 0)
        #expect(lines.map(\.text) == ["First sentence.", "Last."])
        #expect(lines.allSatisfy { $0.start >= 0 && $0.end <= request.section.duration })
    }

    @Test func rejectsMismatchedAndInvalidTimedTranscripts() {
        #expect(throws: SceneTranscriptionError.self) {
            try SceneTranscript(locale: "fr-FR", durationSeconds: 10, words: []).words(for: request)
        }
        #expect(throws: SceneTranscriptionError.self) {
            try SceneTranscript(locale: "en-US", durationSeconds: 5, words: []).words(for: request)
        }
        #expect(throws: SceneTranscriptionError.self) {
            try SceneTranscript(locale: "en-US", durationSeconds: 10, words: [TranscribedWord(text: "Invalid", start: 5, end: 4)]).words(for: request)
        }
    }

    @Test func preservesTokensWhoseProviderTimingHasNoDuration() throws {
        let transcript = SceneTranscript(locale: "en-US", durationSeconds: 10, words: [
            TranscribedWord(text: "A", start: 4, end: 4),
            TranscribedWord(text: "sentence", start: 4, end: 5),
            TranscribedWord(text: "ends.", start: 5, end: 5),
        ])
        #expect(try transcript.words(for: request) == [TranscribedWord(text: "A sentence ends.", start: 0, end: 1)])
    }
}
