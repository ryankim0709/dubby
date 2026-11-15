import AVFoundation
import CryptoKit
import Foundation
import os

/// A curated scene: a licensed clip with prepared background and per-character dialogue tracks, loaded from a
/// validated Scene Manifest v1. Curated scenes are separate from the raw clips in `Media/`: they need no
/// transcription, and their dub replaces exactly one character's dialogue track.
nonisolated struct CuratedScene: Hashable, Sendable, Identifiable {
    /// The manifest's `sceneId`, never derived from a file name.
    let id: String
    let title: String
    let synopsis: String
    /// BCP-47 language of every line, for example `en-US`.
    let locale: String
    let durationSeconds: Double
    let videoURL: URL
    let posterURL: URL
    /// Music and effects with all dialogue removed.
    let backgroundURL: URL
    let characters: [SceneCharacter]
    /// Every line in the scene, sorted by start.
    let lines: [SceneLine]
    let attribution: SceneAttribution

    func character(withID id: SceneCharacter.ID) -> SceneCharacter? {
        characters.first { $0.id == id }
    }

    func lines(spokenBy characterID: SceneCharacter.ID) -> [SceneLine] {
        lines.filter { $0.characterID == characterID }
    }
}

nonisolated struct SceneCharacter: Hashable, Sendable, Identifiable {
    /// The manifest's character id.
    let id: String
    let displayName: String
    let description: String
    /// This character's speech alone, silent elsewhere, lasting the whole scene.
    let dialogueURL: URL
}

/// One line of reference dialogue, timed in seconds from the scene start.
nonisolated struct SceneLine: Hashable, Sendable, Identifiable {
    /// The manifest's line id, stable across builds; the backend knows lines by this id.
    let id: String
    let characterID: SceneCharacter.ID
    let start: Double
    let end: Double
    let text: String
    let referenceVersion: Int
    /// The scene's BCP-47 locale, repeated on each line so a line can be assessed or coached on its own.
    let locale: String
    /// Word timings, when the manifest has them.
    let words: [SceneWord]

    var duration: Double { end - start }
}

nonisolated struct SceneWord: Hashable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

/// What the scene's license requires the app to show.
nonisolated struct SceneAttribution: Hashable, Sendable {
    let work: String
    let creator: String
    let license: String
    let licenseURL: URL?
    let sourceURL: URL?
    /// The exact attribution text the license requires.
    let text: String
}

/// Every curated scene found in a bundle, plus the scenes that failed validation, which are never listed.
nonisolated struct CuratedSceneCatalog: Sendable {
    let scenes: [CuratedScene]
    let failures: [CuratedSceneLoadFailure]

    func scene(withID id: CuratedScene.ID) -> CuratedScene? {
        scenes.first { $0.id == id }
    }
}

nonisolated struct CuratedSceneLoadFailure: Equatable, Sendable {
    let manifestFile: String
    let error: SceneValidationError
}

/// Loads and validates curated scenes. Every rule in Scene Manifest v1 is checked before a scene is offered:
/// the manifest's own rules, then that each file exists, matches its sha256 and is supported media, and that every
/// audio track lasts the video's duration.
nonisolated enum CuratedSceneLoader {
    static let manifestSuffix = "-manifest.json"
    /// Track durations may differ from the video by this much (Scene Manifest v1).
    static let durationTolerance = 0.020
    static let maximumSceneBytes: Int64 = 10_000_000
    static let maximumVideoSize = CGSize(width: 1280, height: 720)
    static let maximumFrameRate: Float = 30
    static let videoDurationRange = 10.0...30.0
    static let audioSampleRate = 48_000.0

    /// Every scene in the bundle. Synchronized folders may flatten resources into the bundle root, so manifests are
    /// found anywhere in the bundle and each manifest's files are looked up next to it.
    @concurrent
    static func loadCatalog(in bundle: Bundle) async -> CuratedSceneCatalog {
        var scenes: [CuratedScene] = []
        var failures: [CuratedSceneLoadFailure] = []
        for manifestURL in manifestURLs(in: bundle) {
            do {
                scenes.append(try await loadScene(manifestURL: manifestURL))
            } catch let error as SceneValidationError {
                failures.append(CuratedSceneLoadFailure(manifestFile: manifestURL.lastPathComponent, error: error))
            } catch {
                failures.append(CuratedSceneLoadFailure(
                    manifestFile: manifestURL.lastPathComponent,
                    error: .unreadableManifest(file: manifestURL.lastPathComponent, reason: error.localizedDescription)
                ))
            }
        }
        return CuratedSceneCatalog(
            scenes: scenes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
            failures: failures
        )
    }

    static func manifestURLs(in bundle: Bundle) -> [URL] {
        guard let root = bundle.resourceURL,
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.hasSuffix(manifestSuffix) && !$0.path(percentEncoded: false).contains(".xctest/") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Exactly the files that valid manifests reference (video, poster, background and dialogue tracks), resolved
    /// next to each manifest, so the raw clip library can leave them out. A manifest that doesn't decode or breaks a
    /// manifest rule claims nothing, and a personal clip that merely shares a scene's name prefix is never claimed.
    static func referencedFiles(manifestURLs: [URL]) -> Set<URL> {
        var files = Set<URL>()
        for manifestURL in manifestURLs {
            do {
                let manifest = try decodeManifest(at: manifestURL)
                try SceneManifestValidator.validate(manifest, supportedLocales: Set(SpokenLanguage.all.map(\.identifier)))
                let folder = manifestURL.deletingLastPathComponent()
                let names = [manifest.video.file, manifest.poster.file, manifest.background.file] + manifest.characters.map(\.dialogue.file)
                files.formUnion(names.map { comparable(folder.appending(path: $0)) })
            } catch {
                logger.warning("Skipping invalid scene manifest \(manifestURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return files
    }

    /// A file URL normalized so two spellings of the same path compare equal.
    static func comparable(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "curatedScenes")

    /// Loads one scene from its manifest, resolving every file in the manifest's folder.
    @concurrent
    static func loadScene(manifestURL: URL) async throws -> CuratedScene {
        let manifest = try decodeManifest(at: manifestURL)
        try SceneManifestValidator.validate(manifest, supportedLocales: Set(SpokenLanguage.all.map(\.identifier)))
        guard manifestURL.lastPathComponent == "\(manifest.sceneId)\(manifestSuffix)" else {
            throw SceneValidationError.fileNameNotScoped(file: manifestURL.lastPathComponent, sceneID: manifest.sceneId)
        }
        let folder = manifestURL.deletingLastPathComponent()
        func verified(_ file: SceneManifest.File) throws -> URL {
            let url = folder.appending(path: file.file)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { throw SceneValidationError.missingFile(file.file) }
            guard try sha256(of: url) == file.sha256.lowercased() else { throw SceneValidationError.checksumMismatch(file: file.file) }
            return url
        }
        let video = try verified(manifest.video)
        let poster = try verified(manifest.poster)
        let background = try verified(manifest.background)
        let dialogue = try manifest.characters.map { try verified($0.dialogue) }

        let allFiles = [manifestURL, video, poster, background] + dialogue
        let bytes = try allFiles.reduce(Int64(0)) { total, url in
            total + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        guard bytes <= maximumSceneBytes else { throw SceneValidationError.sceneTooLarge(bytes: bytes) }

        let videoDuration = try await checkVideo(video, manifestDuration: manifest.durationSeconds)
        for track in [background] + dialogue {
            try await checkAudio(track, videoDuration: videoDuration)
        }

        let characters = zip(manifest.characters, dialogue).map { character, url in
            SceneCharacter(id: character.id, displayName: character.displayName, description: character.description, dialogueURL: url)
        }
        let lines = manifest.lines.map { line in
            SceneLine(
                id: line.id,
                characterID: line.characterId,
                start: line.start,
                end: line.end,
                text: line.text,
                referenceVersion: line.referenceVersion,
                locale: manifest.locale,
                words: (line.words ?? []).map { SceneWord(text: $0.text, start: $0.start, end: $0.end) }
            )
        }
        return CuratedScene(
            id: manifest.sceneId,
            title: manifest.title,
            synopsis: manifest.synopsis,
            locale: manifest.locale,
            durationSeconds: manifest.durationSeconds,
            videoURL: video,
            posterURL: poster,
            backgroundURL: background,
            characters: characters,
            lines: lines,
            attribution: SceneAttribution(
                work: manifest.provenance.work,
                creator: manifest.provenance.creator,
                license: manifest.provenance.license,
                licenseURL: URL(string: manifest.provenance.licenseURL),
                sourceURL: URL(string: manifest.provenance.sourceURL),
                text: manifest.provenance.attribution
            )
        )
    }

    static func decodeManifest(at url: URL) throws -> SceneManifest {
        do {
            return try JSONDecoder().decode(SceneManifest.self, from: Data(contentsOf: url))
        } catch let error as DecodingError {
            throw SceneValidationError.unreadableManifest(file: url.lastPathComponent, reason: describe(error))
        } catch {
            throw SceneValidationError.unreadableManifest(file: url.lastPathComponent, reason: error.localizedDescription)
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing \(([path(context), key.stringValue].filter { !$0.isEmpty }).joined(separator: "."))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "wrong type at \(path(context))"
        case .dataCorrupted(let context):
            return "invalid JSON at \(path(context))"
        @unknown default:
            return "unknown decoding failure"
        }
    }

    /// Scenes are at most 10 MB, so hashing a memory-mapped copy is cheap.
    static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    /// Checks the video against Scene Manifest v1's media rules and returns its duration.
    private static func checkVideo(_ url: URL, manifestDuration: Double) async throws -> Double {
        let file = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SceneValidationError.unsupportedMedia(file: file, reason: "it has no video track")
        }
        let (formats, size, frameRate, timeRange) = try await track.load(.formatDescriptions, .naturalSize, .nominalFrameRate, .timeRange)
        guard formats.contains(where: { $0.mediaSubType == .h264 }) else {
            throw SceneValidationError.unsupportedMedia(file: file, reason: "the video isn't H.264")
        }
        guard size.width <= maximumVideoSize.width, size.height <= maximumVideoSize.height else {
            throw SceneValidationError.unsupportedMedia(file: file, reason: "the video is larger than 1280×720")
        }
        guard frameRate <= maximumFrameRate + 0.01 else {
            throw SceneValidationError.unsupportedMedia(file: file, reason: "the video runs faster than 30 fps")
        }
        let duration = timeRange.end.seconds
        guard videoDurationRange.contains(duration) else {
            throw SceneValidationError.unsupportedMedia(file: file, reason: String(format: "the video lasts %.2f s, outside 10–30 s", duration))
        }
        guard abs(duration - manifestDuration) <= durationTolerance else {
            throw SceneValidationError.durationMismatch(file: file, expected: manifestDuration, actual: duration)
        }
        return duration
    }

    private static func checkAudio(_ url: URL, videoDuration: Double) async throws {
        let file = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SceneValidationError.unsupportedMedia(file: file, reason: "it has no audio track")
        }
        let formats = try await track.load(.formatDescriptions)
        guard let format = formats.first, format.mediaSubType == .mpeg4AAC else {
            throw SceneValidationError.unsupportedMedia(file: file, reason: "the audio isn't AAC")
        }
        guard let sampleRate = format.audioStreamBasicDescription?.mSampleRate, sampleRate == audioSampleRate else {
            throw SceneValidationError.unsupportedMedia(file: file, reason: "the audio isn't 48 kHz")
        }
        // AAC container estimates omit priming; validate the track's actual presentation range.
        let duration = try await track.load(.timeRange).end.seconds
        guard abs(duration - videoDuration) <= durationTolerance else {
            throw SceneValidationError.durationMismatch(file: file, expected: videoDuration, actual: duration)
        }
    }
}
