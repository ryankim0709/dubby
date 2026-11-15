import SwiftUI

struct Artwork: Hashable {
    let imageName: String
    let placeholder: [Color]
}

struct SceneSource: Hashable {
    let title: String
    let year: Int
    let format: String
}

enum Difficulty: String, Hashable {
    case easy = "Easy"
    case medium = "Medium"
    case hard = "Hard"
}

struct SceneCharacter: Hashable, Identifiable {
    let id: String
    let name: String
    let tagline: String
    let artwork: Artwork
}

/// The learner's own language, used for line translations and word meanings.
enum HomeLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh-Hans"
    case english = "en"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .chinese: "中文（简体）"
        case .english: "English"
        }
    }
}

/// One spoken line; times are seconds relative to the start of the scene clip.
struct ScriptLine: Hashable, Identifiable {
    let id: String
    let characterID: String
    let text: String
    /// The line's meaning keyed by language code (`HomeLanguage.rawValue`).
    let translations: [String: String]
    let start: Double
    let end: Double
}

/// Prepared media for a curated scene: a silent picture track, a music-and-effects bed,
/// and one isolated dialogue stem per character, so any one voice can be replaced.
struct SceneMediaFiles: Hashable {
    let video: String
    let bed: String
    let stems: [String: String]
}

struct SceneClip: Hashable, Identifiable {
    let id: String
    let title: String
    let source: SceneSource
    let synopsis: String
    let language: String
    /// Code of the language the scene is spoken in, comparable with `HomeLanguage.rawValue`.
    let languageCode: String
    let duration: Double
    let difficulty: Difficulty
    let artwork: Artwork
    let characters: [SceneCharacter]
    let lines: [ScriptLine]
    let media: SceneMediaFiles
    let dubCount: Int
    /// Word meanings keyed by `Glossary.key(for:)`, then by language code.
    let glossary: [String: [String: String]]

    func character(id: String) -> SceneCharacter? {
        characters.first { $0.id == id }
    }

    func lines(for characterID: String) -> [ScriptLine] {
        lines.filter { $0.characterID == characterID }
    }
}

enum Glossary {
    /// Normalizes a word as written in a line ("¿Quién", "me!") to its glossary key ("quién", "me").
    static func key(for word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces))
    }
}

extension SceneClip {
    /// Learning aids only make sense when the scene isn't already in the learner's language.
    func needsTranslation(for language: HomeLanguage) -> Bool {
        language.rawValue != languageCode
    }

    func translation(of line: ScriptLine, into language: HomeLanguage) -> String? {
        guard needsTranslation(for: language) else { return nil }
        return line.translations[language.rawValue]
    }

    func meaning(of word: String, in language: HomeLanguage) -> String? {
        guard needsTranslation(for: language) else { return nil }
        return glossary[Glossary.key(for: word)]?[language.rawValue]
    }
}

enum SceneValidationIssue: Hashable {
    case invalidTiming(lineID: String)
    case unknownCharacter(lineID: String)
    case missingStem(characterID: String)
}

extension SceneClip {
    /// The invariants recording and rendering rely on, checked before a user starts a dub.
    var validationIssues: [SceneValidationIssue] {
        let characterIDs = Set(characters.map(\.id))
        var issues: [SceneValidationIssue] = []
        for line in lines {
            let hasValidTiming = line.start.isFinite && line.end.isFinite
                && 0 <= line.start && line.start < line.end && line.end <= duration
            if !hasValidTiming {
                issues.append(.invalidTiming(lineID: line.id))
            }
            if !characterIDs.contains(line.characterID) {
                issues.append(.unknownCharacter(lineID: line.id))
            }
        }
        for character in characters where media.stems[character.id] == nil {
            issues.append(.missingStem(characterID: character.id))
        }
        return issues
    }
}

/// One recording of a line. `sceneStart` is the scene time at which capture began, so the
/// take lands on the scene timeline exactly where it was performed.
struct Take: Hashable, Identifiable {
    let id: UUID
    let lineID: String
    let fileURL: URL
    let sceneStart: Double
    let duration: Double
}

/// Everything the wrap screen needs to render and file a finished dub.
struct DubSummary: Hashable {
    let scene: SceneClip
    let characterID: String
    let partner: Friend?
    let takes: [Take]
    let timingScores: [String: Int]
}

// MARK: - Social

struct Friend: Hashable, Identifiable {
    let id: String
    let name: String
    let handle: String
    let avatar: [Color]
}

enum Visibility: Hashable {
    case publicFeed
    case privateShelf
}

enum ShelfDubProgress: Hashable {
    /// `timingScore` is nil when no line in the dub had measurable speech.
    case finished(timingScore: Int?)
    case draft(completedLines: Int, totalLines: Int)
}

struct ShelfDub: Hashable, Identifiable {
    let id: String
    let scene: SceneClip
    let characterID: String
    let collaborator: Friend?
    var visibility: Visibility
    let progress: ShelfDubProgress
    let dateText: String
    /// The rendered file for dubs made on this device; sample entries have none.
    let videoURL: URL?
}

struct FeedPost: Hashable, Identifiable {
    let id: String
    let scene: SceneClip
    /// Each author paired with the character they dubbed.
    let credits: [FeedCredit]
    let caption: String
    let reactions: Int
    let comments: Int
    let postedText: String
}

struct FeedCredit: Hashable {
    let author: Friend
    let characterID: String
}

struct CoDubInvite: Hashable, Identifiable {
    let id: String
    let from: Friend
    let scene: SceneClip
    let theirCharacterID: String
    let yourCharacterID: String
    let sentText: String
}

enum MessageSender: Hashable {
    case me
    case friend
}

enum MessageContent: Hashable {
    case text(String)
    case invite(CoDubInvite)
}

struct ChatMessage: Hashable, Identifiable {
    let id: Int
    let sender: MessageSender
    let content: MessageContent
}

struct Conversation: Hashable, Identifiable {
    let id: String
    let friend: Friend
    let messages: [ChatMessage]
    let lastActivity: String
    let unreadCount: Int
}
