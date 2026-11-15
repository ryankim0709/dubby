import Foundation

/// How the backend produced a coach reply.
nonisolated enum CoachReplySource: String, Codable, Hashable, Sendable {
    case model
    case template
}

/// What a piece of coaching feedback was measured from. Anything the app doesn't recognise is
/// treated as `none`, so the UI never claims a measurement the backend didn't state.
nonisolated enum FeedbackBasis: String, Codable, Hashable, Sendable {
    case acoustic
    case scriptAgreement = "script_agreement"
    case none

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = FeedbackBasis(rawValue: value) ?? .none
    }
}

nonisolated enum ExerciseKind: String, Codable, Hashable, Sendable {
    case drillWord = "drill_word"
    case retryLine = "retry_line"
    case newLine = "new_line"
    case firstAttempt = "first_attempt"
}

nonisolated enum PracticeFocus: String, Codable, Hashable, Sendable, CaseIterable {
    case any
    case pronunciation
    case wordAccuracy = "word_accuracy"
    case fluency
    case timing
}

/// The recorded attempts and assessments an exercise was chosen from.
nonisolated struct ExerciseEvidence: Codable, Hashable, Sendable {
    let attemptIds: [String]
    let assessmentIds: [String]
}

/// The single exercise the backend recommends next, chosen from the learner's measured practice.
nonisolated struct NextExercise: Codable, Hashable, Sendable {
    let kind: ExerciseKind
    let locale: String
    let lineId: String?
    let referenceVersion: Int?
    let practiceText: String?
    let focus: PracticeFocus
    let instruction: String
    let reasonCode: String
    let evidence: ExerciseEvidence
}

/// `/coach/reply`. A response from before the tutoring fields existed is just `{ text }`, which
/// decodes with no source, no cited evidence, and a basis of `none`.
nonisolated struct CoachReply: Decodable, Hashable, Sendable {
    let text: String
    let source: CoachReplySource?
    let feedbackBasis: FeedbackBasis
    let citedEvidenceIds: [String]
    let exercise: NextExercise?

    private enum CodingKeys: String, CodingKey {
        case text, source, feedbackBasis, citedEvidenceIds, exercise
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        source = try container.decodeIfPresent(CoachReplySource.self, forKey: .source)
        feedbackBasis = try container.decodeIfPresent(FeedbackBasis.self, forKey: .feedbackBasis) ?? .none
        citedEvidenceIds = try container.decodeIfPresent([String].self, forKey: .citedEvidenceIds) ?? []
        exercise = try container.decodeIfPresent(NextExercise.self, forKey: .exercise)
    }
}

/// What the learner is practising right now, handed in by the dub flow so the coach can ground
/// its reply in that line. The backend resolves the line's attempts from the signed-in account.
nonisolated struct CoachPracticeContext: Hashable, Sendable {
    let lineID: String
    let locale: String
}

nonisolated enum PracticeChallenge: String, Codable, Hashable, Sendable, CaseIterable {
    case gentle
    case standard
    case stretch
}

nonisolated enum SessionMinutes: Int, Codable, Hashable, Sendable, CaseIterable {
    case five = 5
    case ten = 10
    case twenty = 20
}

/// The learner's explicit coaching preferences. Nothing here is inferred from their practice.
nonisolated struct CoachPreferences: Codable, Hashable, Sendable {
    static let goalNoteLimit = 280

    var targetLocale: String?
    var focus: PracticeFocus
    var challenge: PracticeChallenge
    var sessionMinutes: SessionMinutes?
    var avoidLineIds: [String]
    var goalNote: String?
    var timeZone: String?

    /// What a learner who never saved anything gets before the backend answers.
    static let standard = CoachPreferences(
        targetLocale: nil, focus: .any, challenge: .standard, sessionMinutes: nil,
        avoidLineIds: [], goalNote: nil, timeZone: nil
    )

    var isGoalNoteTooLong: Bool {
        (goalNote?.count ?? 0) > Self.goalNoteLimit
    }

    /// The preferences as they are sent: a blank goal note is dropped rather than stored as spaces.
    var trimmed: CoachPreferences {
        var copy = self
        let note = goalNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        copy.goalNote = note.isEmpty ? nil : note
        return copy
    }
}

/// Preferences with the version the server holds, which a save must quote back.
nonisolated struct CoachPreferencesRecord: Codable, Hashable, Sendable {
    let preferences: CoachPreferences
    let version: Int
}

/// How many of the learner's memory documents are waiting, failed, or stored.
nonisolated struct CoachMemoryStatus: Codable, Hashable, Sendable {
    let pending: Int
    let failed: Int
    let done: Int
}

nonisolated struct ProgressVolume: Decodable, Hashable, Sendable {
    let attempts: Int
    let lines: Int
    let speakingMs: Int
}

/// A mean over `sampleCount` scored attempts. The mean is nil, never zero, when nothing was measured.
nonisolated struct MetricBlock: Decodable, Hashable, Sendable {
    let mean: Double?
    let sampleCount: Int
}

nonisolated struct DailyProgress: Decodable, Hashable, Sendable {
    let day: String
    let firstScorable: [String: MetricBlock]
    let bestAttempt: [String: MetricBlock]
}

/// One progress series. Series that differ in locale, rubric, or evaluator are never merged.
nonisolated struct ProgressSeries: Decodable, Hashable, Sendable {
    let locale: String
    let rubricVersion: String
    let provider: String
    let modelVersion: String?
    let configVersion: String
    let volume: ProgressVolume
    let daily: [DailyProgress]
}

nonisolated struct CoachProgress: Decodable, Hashable, Sendable {
    let generatedAt: String
    let timeZonePolicy: String
    let series: [ProgressSeries]
}

/// The `{ error, code }` body the tutoring routes use for every failure.
nonisolated struct CoachErrorEnvelope: Decodable, Hashable, Sendable {
    let error: String
    let code: String
}
