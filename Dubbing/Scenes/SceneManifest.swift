import Foundation

/// Scene Manifest v1, exactly as bundled at `Dubbing/DemoScenes/<sceneId>/<sceneId>-manifest.json`.
/// Decoding requires every field the engine uses and ignores unknown ones; `SceneManifestValidator` then checks
/// the semantic rules that decoding can't express.
nonisolated struct SceneManifest: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let sceneId: String
    let title: String
    let synopsis: String
    let locale: String
    let durationSeconds: Double
    let video: File
    let poster: File
    let background: File
    let characters: [Character]
    let lines: [Line]
    let provenance: Provenance

    nonisolated struct File: Codable, Hashable, Sendable {
        let file: String
        let sha256: String
    }

    nonisolated struct Character: Codable, Hashable, Sendable {
        let id: String
        let displayName: String
        let description: String
        let dialogue: File
    }

    nonisolated struct Line: Codable, Hashable, Sendable {
        let id: String
        let characterId: String
        let start: Double
        let end: Double
        let text: String
        let referenceVersion: Int
        let words: [Word]?
    }

    nonisolated struct Word: Codable, Hashable, Sendable {
        let text: String
        let start: Double
        let end: Double
    }

    nonisolated struct Provenance: Codable, Hashable, Sendable {
        let work: String
        let creator: String
        let sourceURL: String
        let license: String
        let licenseURL: String
        let attribution: String
    }

    static let supportedSchemaVersion = 1
}

/// Why a curated scene can't be used. Each case names the offending item so the asset author can fix it.
nonisolated enum SceneValidationError: LocalizedError, Equatable, Sendable {
    case unreadableManifest(file: String, reason: String)
    case unsupportedSchemaVersion(Int)
    case invalidSceneID(String)
    case invalidIdentifier(String)
    case duplicateIdentifier(String)
    case unsupportedLocale(String)
    case invalidSceneDuration(Double)
    case invalidLineTiming(lineID: String, start: Double, end: Double)
    case linesNotSortedByStart(lineID: String)
    case unknownCharacter(lineID: String, characterID: String)
    case overlappingLines(characterID: String, first: String, second: String)
    case invalidWordTiming(lineID: String, word: String)
    case tooFewCharacters(Int)
    case noCharacterWithThreeLines
    case fileNameNotScoped(file: String, sceneID: String)
    case missingFile(String)
    case checksumMismatch(file: String)
    case unsupportedMedia(file: String, reason: String)
    case durationMismatch(file: String, expected: Double, actual: Double)
    case sceneTooLarge(bytes: Int64)
    case characterNotInScene(String)

    var errorDescription: String? {
        switch self {
        case .unreadableManifest(let file, let reason):
            "The scene manifest \(file) couldn't be read: \(reason)."
        case .unsupportedSchemaVersion(let version):
            "Scene manifest schema version \(version) isn't supported; this app reads version \(SceneManifest.supportedSchemaVersion)."
        case .invalidSceneID(let id):
            "The scene id \"\(id)\" isn't kebab-case."
        case .invalidIdentifier(let id):
            "The id \"\(id)\" isn't kebab-case."
        case .duplicateIdentifier(let id):
            "The id \"\(id)\" is used more than once."
        case .unsupportedLocale(let locale):
            "The scene's language \(locale) isn't one DubIt supports."
        case .invalidSceneDuration(let seconds):
            "The scene duration \(seconds) s isn't a usable length."
        case .invalidLineTiming(let lineID, let start, let end):
            "Line \(lineID) runs from \(start) s to \(end) s, which isn't inside the scene."
        case .linesNotSortedByStart(let lineID):
            "Line \(lineID) starts before the line listed above it."
        case .unknownCharacter(let lineID, let characterID):
            "Line \(lineID) belongs to \(characterID), who isn't one of the scene's characters."
        case .overlappingLines(let characterID, let first, let second):
            "\(characterID)'s lines \(first) and \(second) overlap."
        case .invalidWordTiming(let lineID, let word):
            "The word \"\(word)\" in line \(lineID) is out of order or outside its line."
        case .tooFewCharacters(let count):
            "A scene needs at least two characters; this one has \(count)."
        case .noCharacterWithThreeLines:
            "A scene needs a character with at least three lines."
        case .fileNameNotScoped(let file, let sceneID):
            "The file \(file) must start with \"\(sceneID)-\"."
        case .missingFile(let file):
            "The scene file \(file) is missing from the app."
        case .checksumMismatch(let file):
            "The scene file \(file) doesn't match its checksum."
        case .unsupportedMedia(let file, let reason):
            "The scene file \(file) can't be used: \(reason)."
        case .durationMismatch(let file, let expected, let actual):
            String(format: "The scene file %@ lasts %.3f s, but the scene lasts %.3f s.", file, actual, expected)
        case .sceneTooLarge(let bytes):
            "The scene's files add up to \(bytes / 1_000_000) MB, more than the 10 MB limit."
        case .characterNotInScene(let id):
            "\(id) isn't a character in this scene."
        }
    }
}

/// The semantic rules of Scene Manifest v1 that need no file access. File and media checks live in `CuratedSceneLoader`.
nonisolated enum SceneManifestValidator {
    static func validate(_ manifest: SceneManifest, supportedLocales: Set<String>) throws {
        guard manifest.schemaVersion == SceneManifest.supportedSchemaVersion else {
            throw SceneValidationError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        guard isKebabCase(manifest.sceneId) else { throw SceneValidationError.invalidSceneID(manifest.sceneId) }
        guard supportedLocales.contains(manifest.locale) else { throw SceneValidationError.unsupportedLocale(manifest.locale) }
        guard manifest.durationSeconds.isFinite, manifest.durationSeconds > 0 else {
            throw SceneValidationError.invalidSceneDuration(manifest.durationSeconds)
        }
        guard manifest.characters.count >= 2 else { throw SceneValidationError.tooFewCharacters(manifest.characters.count) }

        var seen = Set<String>()
        for id in manifest.characters.map(\.id) + manifest.lines.map(\.id) {
            guard isKebabCase(id) else { throw SceneValidationError.invalidIdentifier(id) }
            guard seen.insert(id).inserted else { throw SceneValidationError.duplicateIdentifier(id) }
        }

        let files = [manifest.video.file, manifest.poster.file, manifest.background.file] + manifest.characters.map(\.dialogue.file)
        for file in files where !file.hasPrefix("\(manifest.sceneId)-") || file.contains("/") {
            throw SceneValidationError.fileNameNotScoped(file: file, sceneID: manifest.sceneId)
        }
        if let duplicate = Dictionary(grouping: files, by: { $0 }).first(where: { $0.value.count > 1 })?.key {
            throw SceneValidationError.duplicateIdentifier(duplicate)
        }

        let characterIDs = Set(manifest.characters.map(\.id))
        var previousStart = -Double.infinity
        var lastLineByCharacter: [String: SceneManifest.Line] = [:]
        for line in manifest.lines {
            guard line.start.isFinite, line.end.isFinite, line.start >= 0, line.start < line.end, line.end <= manifest.durationSeconds else {
                throw SceneValidationError.invalidLineTiming(lineID: line.id, start: line.start, end: line.end)
            }
            guard line.start >= previousStart else { throw SceneValidationError.linesNotSortedByStart(lineID: line.id) }
            previousStart = line.start
            guard characterIDs.contains(line.characterId) else {
                throw SceneValidationError.unknownCharacter(lineID: line.id, characterID: line.characterId)
            }
            if let previous = lastLineByCharacter[line.characterId], previous.end > line.start {
                throw SceneValidationError.overlappingLines(characterID: line.characterId, first: previous.id, second: line.id)
            }
            lastLineByCharacter[line.characterId] = line
            try validateWords(of: line)
        }

        let lineCounts = Dictionary(grouping: manifest.lines, by: \.characterId).mapValues(\.count)
        guard lineCounts.values.contains(where: { $0 >= 3 }) else { throw SceneValidationError.noCharacterWithThreeLines }
    }

    private static func validateWords(of line: SceneManifest.Line) throws {
        var previousEnd = line.start
        for word in line.words ?? [] {
            guard
                word.start.isFinite, word.end.isFinite,
                word.start >= previousEnd, word.start <= word.end, word.end <= line.end
            else {
                throw SceneValidationError.invalidWordTiming(lineID: line.id, word: word.text)
            }
            previousEnd = word.end
        }
    }

    /// Lowercase ASCII letters and digits in hyphen-separated groups, like `tears-of-steel-line-01`.
    static func isKebabCase(_ id: String) -> Bool {
        let groups = id.split(separator: "-", omittingEmptySubsequences: false)
        return !id.isEmpty && groups.allSatisfy { group in
            !group.isEmpty && group.allSatisfy { ($0.isASCII && $0.isLowercase) || ($0.isASCII && $0.isNumber) }
        }
    }
}
