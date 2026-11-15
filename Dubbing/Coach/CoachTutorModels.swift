import Foundation

/// How the backend produced a coach reply.
nonisolated enum CoachReplySource: String, Codable, Hashable, Sendable {
    case model
    case template
}

/// Which model wrote a reply. Only replies with `source: model` carry one.
nonisolated struct ReplyProvenance: Decodable, Hashable, Sendable {
    let provider: String
    let api: String
    let model: String
    let responseId: String?

    /// `<provider>/<model>`, the short form the QA ids expose.
    var summary: String { "\(provider)/\(model)" }
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
    let locale: String?
    let lineId: String?
    let referenceVersion: Int?
    let practiceText: String?
    let focus: PracticeFocus
    let instruction: String
    let reasonCode: String
    let basis: FeedbackBasis
    let evidence: ExerciseEvidence
}

/// `/coach/reply`. A response from before the tutoring fields existed is just `{ text }`, which
/// decodes with no source, no provenance, no cited evidence, and a basis of `none`.
nonisolated struct CoachReply: Decodable, Hashable, Sendable {
    let text: String
    let source: CoachReplySource?
    let provenance: ReplyProvenance?
    let feedbackBasis: FeedbackBasis
    let citedEvidenceIds: [String]
    let exercise: NextExercise?

    private enum CodingKeys: String, CodingKey {
        case text, source, provenance, feedbackBasis, citedEvidenceIds, exercise
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        source = try container.decodeIfPresent(CoachReplySource.self, forKey: .source)
        provenance = try container.decodeIfPresent(ReplyProvenance.self, forKey: .provenance)
        feedbackBasis = try container.decodeIfPresent(FeedbackBasis.self, forKey: .feedbackBasis) ?? .none
        citedEvidenceIds = try container.decodeIfPresent([String].self, forKey: .citedEvidenceIds) ?? []
        exercise = try container.decodeIfPresent(NextExercise.self, forKey: .exercise)
    }
}

/// What the learner is practising right now, handed in by the dub flow. The coach uses its
/// language to start on the right locale and its line for the "skip this line" choice.
nonisolated struct CoachPracticeContext: Hashable, Sendable {
    let lineID: String
    let locale: String
}

nonisolated enum PracticeChallenge: String, Codable, Hashable, Sendable, CaseIterable {
    case gentle
    case standard
    case stretch
}

/// Whether the backend may keep derived coaching memory for the learner.
nonisolated enum MemoryMode: String, Codable, Hashable, Sendable {
    case on
    case off
}

/// The learner's explicit coaching preferences. Nothing here is inferred from their practice.
nonisolated struct CoachPreferences: Codable, Hashable, Sendable {
    static let goalNoteLimit = 280
    static let avoidLineLimit = 50

    var targetLocale: String?
    var focus: PracticeFocus
    var challenge: PracticeChallenge
    var avoidLineIds: [String]
    var memory: MemoryMode
    var goalNote: String?

    /// What a learner who never saved anything gets before the backend answers.
    static let standard = CoachPreferences(
        targetLocale: nil, focus: .any, challenge: .standard, avoidLineIds: [], memory: .on, goalNote: nil
    )

    var isGoalNoteTooLong: Bool {
        (goalNote?.count ?? 0) > Self.goalNoteLimit
    }

    var canAvoidMoreLines: Bool {
        avoidLineIds.count < Self.avoidLineLimit
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

nonisolated enum MemoryItemKind: String, Hashable, Sendable {
    case preference
    case attemptNote = "attempt_note"
    case difficulty
    case other
}

nonisolated enum MemoryItemState: String, Hashable, Sendable {
    case pending
    case done
    case failed
    case other
}

/// One thing the coach remembers about the learner, as the backend's outbox holds it. It never
/// carries a score.
nonisolated struct MemoryItem: Decodable, Hashable, Sendable, Identifiable {
    let docId: String
    let kind: MemoryItemKind
    let text: String
    let sourceIds: [String]
    let state: MemoryItemState

    var id: String { docId }

    private enum CodingKeys: String, CodingKey {
        case docId, kind, text, sourceIds, state
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        docId = try container.decode(String.self, forKey: .docId)
        kind = MemoryItemKind(rawValue: try container.decode(String.self, forKey: .kind)) ?? .other
        text = try container.decode(String.self, forKey: .text)
        sourceIds = try container.decode([String].self, forKey: .sourceIds)
        state = MemoryItemState(rawValue: try container.decode(String.self, forKey: .state)) ?? .other
    }
}

// MARK: Progress

nonisolated enum ScoreMetric: String, Hashable, Sendable, CaseIterable {
    case languageOverall
    case pronunciation
    case wordAccuracy
    case fluency
    case timingFit
}

/// The five score metrics, each present or null.
nonisolated struct MetricSet<Value: Decodable & Hashable & Sendable>: Decodable, Hashable, Sendable {
    let languageOverall: Value?
    let pronunciation: Value?
    let wordAccuracy: Value?
    let fluency: Value?
    let timingFit: Value?
}

/// A mean over `samples` scored takes.
nonisolated struct MetricValue: Decodable, Hashable, Sendable {
    let value: Double
    let samples: Int
}

nonisolated enum EvaluatorMeasurement: String, Hashable, Sendable, Decodable {
    case acoustic
    case transcriptOnly = "transcript_only"

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = EvaluatorMeasurement(rawValue: value) ?? .transcriptOnly
    }
}

nonisolated struct ProgressEvaluator: Decodable, Hashable, Sendable {
    let provider: String
    let modelVersion: String?
    let configVersion: String
    let measurement: EvaluatorMeasurement
}

nonisolated struct UnavailableMetric: Decodable, Hashable, Sendable {
    let metric: String
    let reason: String
}

nonisolated struct ProgressVolume: Decodable, Hashable, Sendable {
    let sessions: Int
    let attempts: Int
    let scorableAttempts: Int
    let lines: Int
    let practiceDays: Int
    let speakingMs: Int
}

nonisolated struct DailyProgress: Decodable, Hashable, Sendable {
    let date: String
    let firstScorable: MetricSet<MetricValue>
    let bestAttempt: MetricSet<MetricValue>
}

nonisolated struct DatedValue: Decodable, Hashable, Sendable {
    let date: String
    let value: Double
}

nonisolated enum SkillDirection: String, Hashable, Sendable {
    case improving
    case declining
    case steady
    case insufficientHistory = "insufficient_history"
    case other
}

nonisolated struct SkillTrend: Decodable, Hashable, Sendable {
    let metric: String
    let first: DatedValue?
    let latest: DatedValue?
    let change: Double?
    let direction: SkillDirection

    private enum CodingKeys: String, CodingKey {
        case metric, first, latest, change, direction
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metric = try container.decode(String.self, forKey: .metric)
        first = try container.decodeIfPresent(DatedValue.self, forKey: .first)
        latest = try container.decodeIfPresent(DatedValue.self, forKey: .latest)
        change = try container.decodeIfPresent(Double.self, forKey: .change)
        direction = SkillDirection(rawValue: try container.decode(String.self, forKey: .direction)) ?? .other
    }
}

nonisolated struct PracticedLine: Decodable, Hashable, Sendable {
    let sceneId: String
    let lineId: String
    let referenceVersion: Int
    let referenceText: String
    let attempts: Int
    let latestAttemptId: String
    let latestAssessmentId: String
    let latestRecordedAt: String
    let latestStatus: String
    let latestScores: MetricSet<Double>?
}

nonisolated struct EvidencedValue: Decodable, Hashable, Sendable {
    let date: String
    let value: Double
    let attemptId: String
    let assessmentId: String
}

nonisolated struct RepeatedLine: Decodable, Hashable, Sendable {
    let sceneId: String
    let lineId: String
    let referenceVersion: Int
    let referenceText: String
    let first: EvidencedValue
    let latest: EvidencedValue
    let change: Double
}

/// A word the learner keeps having trouble with, with the attempts that show it.
nonisolated struct DifficultWord: Decodable, Hashable, Sendable {
    let word: String
    let status: String
    let occurrences: Int
    let issueCount: Int
    let issueSessions: Int
    let scriptIssueCount: Int
    let pronunciationIssueCount: Int
    let latestPronunciationScore: Double?
    let issueAttemptIds: [String]
    let issueAssessmentIds: [String]
    let scriptIssueAssessmentIds: [String]
    let pronunciationIssueAssessmentIds: [String]
}

nonisolated struct FocusArea: Decodable, Hashable, Sendable {
    let kind: String
    let word: String?
    let status: String?
    let issueCount: Int?
    let issueAttemptIds: [String]?
}

nonisolated struct RetryLine: Decodable, Hashable, Sendable {
    let sceneId: String
    let lineId: String
    let referenceVersion: Int
    let referenceText: String
    let practiceWords: [String]
    let latestLanguageOverall: Double?
    let latestAttemptId: String
    let latestAssessmentId: String
}

nonisolated struct NewLine: Decodable, Hashable, Sendable {
    let sceneId: String
    let lineId: String
    let referenceVersion: Int
    let referenceText: String
}

nonisolated struct ProgressGuidance: Decodable, Hashable, Sendable {
    let summary: String
    let focusAreas: [FocusArea]
    let retryLines: [RetryLine]
    let newLines: [NewLine]
}

/// One progress series. Series that differ in locale, rubric, or evaluator are never merged.
nonisolated struct ProgressSeries: Decodable, Hashable, Sendable {
    let locale: String
    let rubricVersion: String
    let evaluator: ProgressEvaluator
    let pronunciationBasis: FeedbackBasis
    let unavailableMetrics: [UnavailableMetric]
    let volume: ProgressVolume
    let daily: [DailyProgress]
    let skills: [SkillTrend]
    let lines: [PracticedLine]
    let repeatedLines: [RepeatedLine]
    let words: [DifficultWord]
    let guidance: ProgressGuidance
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
