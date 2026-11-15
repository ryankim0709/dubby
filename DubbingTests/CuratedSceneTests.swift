import Foundation
import Testing
@testable import Dubbing

/// Manifest rules that need no files, checked against a valid synthetic manifest with one thing broken at a time.
struct SceneManifestValidationTests {
    private let locales: Set<String> = ["en-US", "ko-KR"]

    private func manifest(
        locale: String = "en-US",
        schemaVersion: Int = 1,
        characters: [String] = ["alice", "bob"],
        lines: [SceneManifest.Line]? = nil,
        videoFile: String = "scene-video.mp4"
    ) -> SceneManifest {
        let file = { (name: String) in SceneManifest.File(file: name, sha256: "00") }
        return SceneManifest(
            schemaVersion: schemaVersion,
            sceneId: "scene",
            title: "Scene",
            synopsis: "",
            locale: locale,
            durationSeconds: 10,
            video: file(videoFile),
            poster: file("scene-poster.jpg"),
            background: file("scene-background.m4a"),
            characters: characters.map { SceneManifest.Character(id: $0, displayName: $0, description: "", dialogue: file("scene-dialogue-\($0).m4a")) },
            lines: lines ?? [
                line("scene-line-01", "alice", 1, 2),
                line("scene-line-02", "bob", 2.5, 3),
                line("scene-line-03", "alice", 3.5, 4),
                line("scene-line-04", "alice", 5, 6),
            ],
            provenance: SceneManifest.Provenance(work: "", creator: "", sourceURL: "", license: "", licenseURL: "", attribution: "")
        )
    }

    private func line(_ id: String, _ character: String, _ start: Double, _ end: Double, words: [SceneManifest.Word]? = nil) -> SceneManifest.Line {
        SceneManifest.Line(id: id, characterId: character, start: start, end: end, text: "Text", referenceVersion: 1, words: words)
    }

    private func error(of manifest: SceneManifest) -> SceneValidationError? {
        do {
            try SceneManifestValidator.validate(manifest, supportedLocales: locales)
            return nil
        } catch let error as SceneValidationError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    @Test func acceptsAValidManifest() {
        #expect(error(of: manifest()) == nil)
    }

    @Test func rejectsEachBrokenRule() {
        #expect(error(of: manifest(schemaVersion: 2)) == .unsupportedSchemaVersion(2))
        #expect(error(of: manifest(locale: "xx-XX")) == .unsupportedLocale("xx-XX"))
        #expect(error(of: manifest(characters: ["alice"], lines: [line("scene-line-01", "alice", 1, 2)])) == .tooFewCharacters(1))
        #expect(error(of: manifest(videoFile: "video.mp4")) == .fileNameNotScoped(file: "video.mp4", sceneID: "scene"))
        #expect(error(of: manifest(lines: [line("scene-line-01", "alice", 2, 1)])) == .invalidLineTiming(lineID: "scene-line-01", start: 2, end: 1))
        #expect(error(of: manifest(lines: [line("scene-line-01", "alice", 9, 10.5)])) == .invalidLineTiming(lineID: "scene-line-01", start: 9, end: 10.5))
        #expect(error(of: manifest(lines: [line("scene-line-01", "alice", .nan, 1)])) != nil)
        #expect(error(of: manifest(lines: [line("scene-line-01", "alice", 3, 4), line("scene-line-02", "bob", 1, 2)])) == .linesNotSortedByStart(lineID: "scene-line-02"))
        #expect(error(of: manifest(lines: [line("scene-line-01", "carol", 1, 2)])) == .unknownCharacter(lineID: "scene-line-01", characterID: "carol"))
        #expect(
            error(of: manifest(lines: [line("scene-line-01", "alice", 1, 3), line("scene-line-02", "alice", 2, 4)]))
                == .overlappingLines(characterID: "alice", first: "scene-line-01", second: "scene-line-02")
        )
        #expect(
            error(of: manifest(lines: [line("scene-line-01", "alice", 1, 2, words: [SceneManifest.Word(text: "late", start: 1.5, end: 2.5)])]))
                == .invalidWordTiming(lineID: "scene-line-01", word: "late")
        )
        #expect(error(of: manifest(lines: [line("scene-line-01", "alice", 1, 2), line("scene-line-02", "bob", 3, 4)])) == .noCharacterWithThreeLines)
        #expect(error(of: manifest(lines: [line("scene-line-01", "alice", 1, 2), line("scene-line-01", "bob", 3, 4)])) == .duplicateIdentifier("scene-line-01"))
        #expect(error(of: manifest(lines: [line("Scene_Line", "alice", 1, 2)])) == .invalidIdentifier("Scene_Line"))
    }

    @Test func allowsOverlapsBetweenCharacters() {
        let lines = [
            line("scene-line-01", "alice", 1, 3),
            line("scene-line-02", "bob", 2, 4),
            line("scene-line-03", "alice", 4, 5),
            line("scene-line-04", "alice", 6, 7),
        ]
        #expect(error(of: manifest(lines: lines)) == nil)
    }
}

/// Loading the synthetic scene from files, and the file and media failures the loader reports.
struct CuratedSceneLoaderTests {
    @Test func loadsTheSyntheticSceneAndBuildsTheStudioSetupFromTheManifest() async throws {
        let folder = scratchFolder("CuratedSceneLoaderTests")
        let manifestURL = try await SyntheticScene.make(in: folder)
        let scene = try await CuratedSceneLoader.loadScene(manifestURL: manifestURL)
        #expect(scene.id == SyntheticScene.sceneID)
        #expect(scene.locale == "en-US")
        #expect(scene.characters.map(\.id) == ["alice", "bob"])
        #expect(scene.lines.map(\.id) == SyntheticScene.lines.map(\.id))
        #expect(scene.lines.allSatisfy { $0.locale == "en-US" })

        let setup = try await CuratedSceneStudio.makeSetup(scene: scene, characterID: "bob", barCount: 8, workingDirectory: folder.appending(path: "work"))
        #expect(setup.curated?.characterID == "bob")
        #expect(setup.section == ClipSection(start: 0, end: SyntheticScene.duration))
        #expect(setup.script.speaker(withID: setup.characterID)?.name == "Bob")
        let bobLines = setup.script.lines(spokenBy: setup.characterID)
        #expect(bobLines.compactMap(\.reference?.lineID) == ["synthetic-test-scene-line-02", "synthetic-test-scene-line-04", "synthetic-test-scene-line-06"])
        #expect(bobLines.allSatisfy { $0.reference?.locale == "en-US" && $0.reference?.characterID == "bob" })
        #expect(bobLines.map(\.start) == [2.2, 5.0, 8.0])
        // Waveforms come from Bob's own track, so each of his lines has a visible envelope.
        #expect(bobLines.allSatisfy { $0.envelope.count == 8 && ($0.envelope.max() ?? 0) > 0 })
        #expect(throws: SceneValidationError.characterNotInScene("carol")) {
            try CuratedSceneSelection(scene: scene, characterID: "carol")
        }
    }

    @Test func reportsMissingChangedAndMismatchedFiles() async throws {
        let folder = scratchFolder("CuratedSceneLoaderFailures")
        let manifestURL = try await SyntheticScene.make(in: folder)
        let manifest = try CuratedSceneLoader.decodeManifest(at: manifestURL)

        func expectFailure(_ expected: SceneValidationError, after change: (URL) throws -> Void) async throws {
            let copy = scratchFolder("CuratedSceneLoaderFailureCase")
            try FileManager.default.copyItem(at: folder, to: copy)
            try change(copy)
            await #expect(throws: expected) {
                _ = try await CuratedSceneLoader.loadScene(manifestURL: copy.appending(path: manifestURL.lastPathComponent))
            }
        }

        let poster = SyntheticScene.fileName("poster.jpg")
        try await expectFailure(.missingFile(poster)) { copy in
            try FileManager.default.removeItem(at: copy.appending(path: poster))
        }
        try await expectFailure(.checksumMismatch(file: poster)) { copy in
            try Data([0xFF, 0xD8, 0x00, 0xFF, 0xD9]).write(to: copy.appending(path: poster))
        }
        try await expectFailure(.unreadableManifest(file: manifestURL.lastPathComponent, reason: "missing sceneId")) { copy in
            var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
            json.removeValue(forKey: "sceneId")
            try JSONSerialization.data(withJSONObject: json).write(to: copy.appending(path: manifestURL.lastPathComponent))
        }

        // A dialogue track 0.5 s shorter than the video, with a matching checksum, fails the duration rule.
        let bob = SyntheticScene.fileName("dialogue-bob.m4a")
        let shortCopy = scratchFolder("CuratedSceneLoaderShortTrack")
        try FileManager.default.copyItem(at: folder, to: shortCopy)
        try ToneAudio.writeAAC(
            ToneAudio.tone(SyntheticScene.bobHz, amplitude: 0.2, seconds: SyntheticScene.duration - 0.5, sampleRate: SyntheticScene.sampleRate),
            sampleRate: SyntheticScene.sampleRate,
            to: shortCopy.appending(path: bob)
        )
        let rehashed = try SyntheticScene.manifest(in: shortCopy)
        try JSONEncoder().encode(rehashed).write(to: shortCopy.appending(path: manifestURL.lastPathComponent))
        do {
            _ = try await CuratedSceneLoader.loadScene(manifestURL: shortCopy.appending(path: manifestURL.lastPathComponent))
            Issue.record("a short dialogue track should fail validation")
        } catch let error as SceneValidationError {
            guard case .durationMismatch(let file, _, let actual) = error else {
                Issue.record("expected a duration mismatch, got \(error)")
                return
            }
            #expect(file == bob)
            #expect(abs(actual - (SyntheticScene.duration - 0.5)) < 0.05)
        }
        #expect(manifest.sceneId == SyntheticScene.sceneID)
    }

    @Test func rawClipLibraryHidesOnlyTheFilesAManifestReferences() async throws {
        let folder = scratchFolder("CuratedSceneLibrary")
        let manifestURL = try await SyntheticScene.make(in: folder)
        let personalClip = folder.appending(path: "\(SyntheticScene.sceneID)-holiday.mp4")
        try FileManager.default.copyItem(at: folder.appending(path: SyntheticScene.fileName("video.mp4")), to: personalClip)
        let otherClip = folder.appending(path: "my-clip.mp4")
        try FileManager.default.copyItem(at: personalClip, to: otherClip)

        let sceneFiles = CuratedSceneLoader.referencedFiles(manifestURLs: [manifestURL])
        let shown = MediaLibrary.rawClipURLs([folder.appending(path: SyntheticScene.fileName("video.mp4")), personalClip, otherClip], excluding: sceneFiles)
        #expect(shown.map(\.lastPathComponent) == [personalClip.lastPathComponent, otherClip.lastPathComponent])

        // A manifest that breaks a rule claims nothing.
        let broken = folder.appending(path: "broken-scene-manifest.json")
        try Data("{}".utf8).write(to: broken)
        #expect(CuratedSceneLoader.referencedFiles(manifestURLs: [broken]).isEmpty)
    }
}
