import Foundation

// Models for the grading contract in docs/grading-contract.md (schema 1, rubric language-v1).
// The backend assembles and validates the response; the app decodes it, validates it again at its own boundary,
// and never computes or fills in a score. Nothing here accepts an on-device transcript as a measurement.

nonisolated enum AssessmentStatus: String, Codable, Sendable {
    case scored
    case unscorable
}

nonisolated enum UnscorableReason: String, Codable, Sendable {
    case noSpeech = "no_speech"
    case excessiveNoise = "excessive_noise"
    case insufficientSpeech = "insufficient_speech"
    case unsupportedLocale = "unsupported_locale"
}

nonisolated enum AssessmentMetric: String, Codable, CaseIterable, Sendable {
    case languageOverall
    case pronunciation
    case wordAccuracy
    case fluency
    case timingFit
}

nonisolated enum MetricUnavailableReason: String, Codable, Sendable {
    case unsupportedLocale = "unsupported_locale"
    case insufficientEvidence = "insufficient_evidence"
    case missingComponents = "missing_components"
}

nonisolated enum WordTextStatus: String, Codable, Sendable {
    case matched
    case substituted
    case omitted
    case inserted
}

nonisolated enum WordPronunciationUnavailableReason: String, Codable, Sendable {
    case omittedWord = "omitted_word"
    case unalignedWord = "unaligned_word"
    case unsupportedLocale = "unsupported_locale"
    case insufficientEvidence = "insufficient_evidence"
}

nonisolated enum CoachingFocusKind: String, Codable, Sendable {
    case pronunciation
    case wordAccuracy = "word_accuracy"
    case fluency
    case timing
}

/// Every property is present in the JSON and is either a number from 0 through 100 or null.
nonisolated struct AssessmentScores: Codable, Equatable, Sendable {
    var languageOverall: Double?
    var pronunciation: Double?
    var wordAccuracy: Double?
    var fluency: Double?
    var timingFit: Double?

    subscript(metric: AssessmentMetric) -> Double? {
        switch metric {
        case .languageOverall: languageOverall
        case .pronunciation: pronunciation
        case .wordAccuracy: wordAccuracy
        case .fluency: fluency
        case .timingFit: timingFit
        }
    }

    init(languageOverall: Double?, pronunciation: Double?, wordAccuracy: Double?, fluency: Double?, timingFit: Double?) {
        self.languageOverall = languageOverall
        self.pronunciation = pronunciation
        self.wordAccuracy = wordAccuracy
        self.fluency = fluency
        self.timingFit = timingFit
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        languageOverall = try container.decode(Double?.self, forKey: .languageOverall)
        pronunciation = try container.decode(Double?.self, forKey: .pronunciation)
        wordAccuracy = try container.decode(Double?.self, forKey: .wordAccuracy)
        fluency = try container.decode(Double?.self, forKey: .fluency)
        timingFit = try container.decode(Double?.self, forKey: .timingFit)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(languageOverall, forKey: .languageOverall)
        try container.encode(pronunciation, forKey: .pronunciation)
        try container.encode(wordAccuracy, forKey: .wordAccuracy)
        try container.encode(fluency, forKey: .fluency)
        try container.encode(timingFit, forKey: .timingFit)
    }

    private enum CodingKeys: String, CodingKey {
        case languageOverall, pronunciation, wordAccuracy, fluency, timingFit
    }
}

nonisolated struct UnavailableMetric: Codable, Equatable, Sendable {
    var metric: AssessmentMetric
    var reason: MetricUnavailableReason
}

nonisolated struct AssessedWord: Codable, Equatable, Sendable {
    /// Zero-based reference token index; nil for an insertion.
    var referenceWordIndex: Int?
    var expected: String?
    var recognized: String?
    var textStatus: WordTextStatus
    /// Measured by the speech engine; a matched word may still score low.
    var pronunciationScore: Double?
    var pronunciationUnavailableReason: WordPronunciationUnavailableReason?
    /// Recording-relative milliseconds with an exclusive end; nil when not measured.
    var startMs: Int?
    var endMs: Int?

    init(
        referenceWordIndex: Int?,
        expected: String?,
        recognized: String?,
        textStatus: WordTextStatus,
        pronunciationScore: Double?,
        pronunciationUnavailableReason: WordPronunciationUnavailableReason? = nil,
        startMs: Int?,
        endMs: Int?
    ) {
        self.referenceWordIndex = referenceWordIndex
        self.expected = expected
        self.recognized = recognized
        self.textStatus = textStatus
        self.pronunciationScore = pronunciationScore
        self.pronunciationUnavailableReason = pronunciationUnavailableReason
        self.startMs = startMs
        self.endMs = endMs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        referenceWordIndex = try container.decode(Int?.self, forKey: .referenceWordIndex)
        expected = try container.decode(String?.self, forKey: .expected)
        recognized = try container.decode(String?.self, forKey: .recognized)
        textStatus = try container.decode(WordTextStatus.self, forKey: .textStatus)
        pronunciationScore = try container.decode(Double?.self, forKey: .pronunciationScore)
        pronunciationUnavailableReason = try container.decodeIfPresent(WordPronunciationUnavailableReason.self, forKey: .pronunciationUnavailableReason)
        startMs = try container.decode(Int?.self, forKey: .startMs)
        endMs = try container.decode(Int?.self, forKey: .endMs)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(referenceWordIndex, forKey: .referenceWordIndex)
        try container.encode(expected, forKey: .expected)
        try container.encode(recognized, forKey: .recognized)
        try container.encode(textStatus, forKey: .textStatus)
        try container.encode(pronunciationScore, forKey: .pronunciationScore)
        try container.encodeIfPresent(pronunciationUnavailableReason, forKey: .pronunciationUnavailableReason)
        try container.encode(startMs, forKey: .startMs)
        try container.encode(endMs, forKey: .endMs)
    }

    private enum CodingKeys: String, CodingKey {
        case referenceWordIndex, expected, recognized, textStatus, pronunciationScore, pronunciationUnavailableReason, startMs, endMs
    }
}

nonisolated struct CoachingFocus: Codable, Equatable, Sendable {
    var kind: CoachingFocusKind
    var referenceWordIndex: Int?
    var instruction: String
    var practiceText: String

    init(kind: CoachingFocusKind, referenceWordIndex: Int?, instruction: String, practiceText: String) {
        self.kind = kind
        self.referenceWordIndex = referenceWordIndex
        self.instruction = instruction
        self.practiceText = practiceText
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(CoachingFocusKind.self, forKey: .kind)
        referenceWordIndex = try container.decode(Int?.self, forKey: .referenceWordIndex)
        instruction = try container.decode(String.self, forKey: .instruction)
        practiceText = try container.decode(String.self, forKey: .practiceText)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(referenceWordIndex, forKey: .referenceWordIndex)
        try container.encode(instruction, forKey: .instruction)
        try container.encode(practiceText, forKey: .practiceText)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, referenceWordIndex, instruction, practiceText
    }
}

nonisolated struct AssessmentCoaching: Codable, Equatable, Sendable {
    var summary: String
    var strengths: [String]
    var focus: [CoachingFocus]
}

/// One graded attempt. A `scored` response carries scores and word results; an `unscorable` one carries a reason and no scores.
nonisolated struct AssessmentResponse: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var rubricVersion: String
    var assessmentId: String
    var attemptId: String
    var lineId: String
    var referenceVersion: Int
    var locale: String
    /// RFC 3339 capture time copied from validated attempt metadata.
    var recordedAt: String
    var status: AssessmentStatus
    /// Present only when status is unscorable.
    var reason: UnscorableReason?
    var referenceText: String
    var recognizedText: String?
    /// Nil exactly when status is unscorable.
    var scores: AssessmentScores?
    var unavailableMetrics: [UnavailableMetric]
    var wordResults: [AssessedWord]
    var coaching: AssessmentCoaching

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        rubricVersion = try container.decode(String.self, forKey: .rubricVersion)
        assessmentId = try container.decode(String.self, forKey: .assessmentId)
        attemptId = try container.decode(String.self, forKey: .attemptId)
        lineId = try container.decode(String.self, forKey: .lineId)
        referenceVersion = try container.decode(Int.self, forKey: .referenceVersion)
        locale = try container.decode(String.self, forKey: .locale)
        recordedAt = try container.decode(String.self, forKey: .recordedAt)
        status = try container.decode(AssessmentStatus.self, forKey: .status)
        reason = try container.decodeIfPresent(UnscorableReason.self, forKey: .reason)
        referenceText = try container.decode(String.self, forKey: .referenceText)
        recognizedText = try container.decode(String?.self, forKey: .recognizedText)
        scores = try container.decode(AssessmentScores?.self, forKey: .scores)
        unavailableMetrics = try container.decode([UnavailableMetric].self, forKey: .unavailableMetrics)
        wordResults = try container.decode([AssessedWord].self, forKey: .wordResults)
        coaching = try container.decode(AssessmentCoaching.self, forKey: .coaching)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(rubricVersion, forKey: .rubricVersion)
        try container.encode(assessmentId, forKey: .assessmentId)
        try container.encode(attemptId, forKey: .attemptId)
        try container.encode(lineId, forKey: .lineId)
        try container.encode(referenceVersion, forKey: .referenceVersion)
        try container.encode(locale, forKey: .locale)
        try container.encode(recordedAt, forKey: .recordedAt)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encode(referenceText, forKey: .referenceText)
        try container.encode(recognizedText, forKey: .recognizedText)
        try container.encode(scores, forKey: .scores)
        try container.encode(unavailableMetrics, forKey: .unavailableMetrics)
        try container.encode(wordResults, forKey: .wordResults)
        try container.encode(coaching, forKey: .coaching)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, rubricVersion, assessmentId, attemptId, lineId, referenceVersion, locale, recordedAt, status, reason
        case referenceText, recognizedText, scores, unavailableMetrics, wordResults, coaching
    }
}
