import Foundation
import Testing
@testable import Dubbing

struct ScriptPreparationTests {
    @Test func preparesDifferentSectionsFromTheSamePublishedDialogue() async throws {
        let folder = try TemporaryDirectory(prefix: "ScriptPreparationTests")
        let clip = ImportedClip(url: try TestFixtures.twoToneVideo(), title: "Synthetic scene", durationSeconds: 3, origin: .published, workingDirectory: folder.url)
        let language = SpokenLanguage(identifier: "en-US", name: "English")
        let transcript = SceneTranscript(locale: language.identifier, durationSeconds: 3, words: [
            TranscribedWord(text: "First.", start: 0.3, end: 0.8),
            TranscribedWord(text: "Second.", start: 1.3, end: 1.8),
            TranscribedWord(text: "Last.", start: 2.3, end: 2.8),
        ])
        let cast = SceneCast(characters: [
            SceneCast.Character(name: "First voice", portraitSeconds: 0.5, faceCenterX: nil),
            SceneCast.Character(name: "Second voice", portraitSeconds: 1.5, faceCenterX: nil),
        ], segments: [
            SceneCast.Segment(start: 0.3, end: 0.8, character: 0),
            SceneCast.Segment(start: 1.3, end: 1.8, character: 1),
            SceneCast.Segment(start: 2.3, end: 2.8, character: 0),
        ])
        let dialogue = SceneDialogue.published(transcript, cast)
        let firstRequest = TranscriptionRequest(clip: clip, section: ClipSection(start: 0, end: 2), sceneLanguage: language, dubLanguage: language)
        let movedRequest = TranscriptionRequest(clip: clip, section: ClipSection(start: 1, end: 3), sceneLanguage: language, dubLanguage: language)

        let first = try await ScriptPreparation.prepare(firstRequest, dialogue: dialogue)
        let moved = try await ScriptPreparation.prepare(movedRequest, dialogue: dialogue)
        guard case .cast(let firstScript, let firstCast) = first.source,
              case .cast(let movedScript, let movedCast) = moved.source else {
            Issue.record("Published dialogue must preserve its shared cast")
            return
        }
        #expect(first.request == firstRequest)
        #expect(moved.request == movedRequest)
        #expect(firstCast == cast && movedCast == cast)
        #expect(firstScript.lines.map(\.text) == ["First.", "Second."])
        #expect(movedScript.lines.map(\.text) == ["Second.", "Last."])
        #expect(movedScript.lines.map(\.speakerID) == [1, 0])
        #expect(abs(try #require(movedScript.lines.first).start - 0.3) < 0.001)
        #expect(movedScript.lines.allSatisfy { $0.start >= 0 && $0.end <= movedRequest.section.duration && $0.envelope.count == 48 })
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path()).isEmpty)
    }

    @Test func emptySectionsFailWithoutLeavingAnAudioExport() async throws {
        let folder = try TemporaryDirectory(prefix: "EmptyScriptPreparationTests")
        let clip = ImportedClip(url: try TestFixtures.twoToneVideo(), title: "Synthetic scene", durationSeconds: 3, origin: .published, workingDirectory: folder.url)
        let request = TranscriptionRequest(clip: clip, section: ClipSection(start: 0, end: 1), sceneLanguage: SpokenLanguage(identifier: "en-US", name: "English"), dubLanguage: SpokenLanguage(identifier: "en-US", name: "English"))
        let transcript = SceneTranscript(locale: "en-US", durationSeconds: 3, words: [TranscribedWord(text: "Later.", start: 2, end: 2.5)])
        let cast = SceneCast(characters: [SceneCast.Character(name: "Voice", portraitSeconds: nil, faceCenterX: nil)], segments: [SceneCast.Segment(start: 2, end: 2.5, character: 0)])
        await #expect(throws: DubFlowError.noSpeechFound) {
            try await ScriptPreparation.prepare(request, dialogue: .published(transcript, cast))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path()).isEmpty)
    }
}
