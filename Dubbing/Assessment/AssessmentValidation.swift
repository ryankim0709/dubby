import Foundation

/// Raised when a decoded response breaks a rule in the grading contract. Mirrors convex/assessment/validate.ts, except that
/// the Swift side does not re-tokenize the reference text, so the backend alone verifies that the alignment covers every reference token.
nonisolated struct AssessmentValidationError: LocalizedError, Equatable {
    let issues: [String]

    var errorDescription: String? {
        "The assessment response broke the grading contract: \(issues.joined(separator: "; "))."
    }
}

nonisolated enum AssessmentContract {
    static let schemaVersion = 1
    static let rubricVersion = "language-v1"

    /// Decodes and validates one response. A decode failure (missing key, unknown enum value, wrong type) throws `DecodingError`;
    /// a rule violation throws `AssessmentValidationError`.
    static func decode(_ data: Data, recordingDurationMs: Int? = nil) throws -> AssessmentResponse {
        let response = try JSONDecoder().decode(AssessmentResponse.self, from: data)
        try response.validate(recordingDurationMs: recordingDurationMs)
        return response
    }
}

extension AssessmentResponse {
    /// Checks the rules the contract states: versions, identifiers, score bounds, null reasons, reference indices,
    /// alignment consistency, timestamps and, when given, recording bounds.
    nonisolated func validate(recordingDurationMs: Int? = nil) throws {
        var issues: [String] = []
        validateEnvelope(into: &issues)
        switch status {
        case .unscorable:
            validateUnscorable(into: &issues)
        case .scored:
            validateScored(recordingDurationMs: recordingDurationMs, into: &issues)
        }
        validateCoaching(into: &issues)
        if !issues.isEmpty { throw AssessmentValidationError(issues: issues) }
    }

    private nonisolated func validateEnvelope(into issues: inout [String]) {
        if schemaVersion != AssessmentContract.schemaVersion { issues.append("schemaVersion must be \(AssessmentContract.schemaVersion)") }
        if rubricVersion != AssessmentContract.rubricVersion { issues.append("rubricVersion must be \(AssessmentContract.rubricVersion)") }
        for (name, value) in [("assessmentId", assessmentId), ("attemptId", attemptId), ("lineId", lineId), ("locale", locale), ("referenceText", referenceText)]
        where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("\(name) must be a non-empty string")
        }
        if referenceVersion < 1 { issues.append("referenceVersion must be a positive integer") }
        if !Self.isRFC3339(recordedAt) { issues.append("recordedAt must be an RFC 3339 timestamp") }
    }

    private nonisolated static func isRFC3339(_ text: String) -> Bool {
        let shape = #/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/#
        guard text.wholeMatch(of: shape) != nil else { return false }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) != nil || fractional.date(from: text) != nil
    }

    private nonisolated func validateUnscorable(into issues: inout [String]) {
        if reason == nil { issues.append("reason is required when unscorable") }
        if scores != nil { issues.append("scores must be null when unscorable") }
        if !wordResults.isEmpty { issues.append("wordResults must be empty when unscorable") }
        if !unavailableMetrics.isEmpty { issues.append("unavailableMetrics must be empty when unscorable") }
        if !coaching.strengths.isEmpty || !coaching.focus.isEmpty { issues.append("coaching must have empty strengths and focus when unscorable") }
    }

    private nonisolated func validateScored(recordingDurationMs: Int?, into issues: inout [String]) {
        if reason != nil { issues.append("reason must be absent when scored") }
        guard let scores else {
            issues.append("scores are required when scored")
            return
        }

        var measured = Set<AssessmentMetric>()
        for metric in AssessmentMetric.allCases {
            guard let value = scores[metric] else { continue }
            if value.isFinite && (0...100).contains(value) {
                measured.insert(metric)
            } else {
                issues.append("scores.\(metric.rawValue) must be null or a finite number from 0 through 100")
            }
        }
        let components: [AssessmentMetric] = [.pronunciation, .wordAccuracy, .fluency]
        let allComponents = components.allSatisfy(measured.contains)
        if !allComponents && measured.contains(.languageOverall) { issues.append("scores.languageOverall must be null when a component is missing") }
        if allComponents && !measured.contains(.languageOverall) { issues.append("scores.languageOverall must be present when every component is measured") }
        if !components.contains(where: measured.contains) { issues.append("scored responses need at least one language measurement") }

        var listed = Set<AssessmentMetric>()
        for entry in unavailableMetrics {
            if !listed.insert(entry.metric).inserted { issues.append("unavailableMetrics duplicates \(entry.metric.rawValue)") }
            if entry.reason == .missingComponents && entry.metric != .languageOverall { issues.append("unavailableMetrics may use missing_components only for languageOverall") }
            if entry.metric == .languageOverall && entry.reason != .missingComponents { issues.append("unavailableMetrics must use missing_components for languageOverall") }
        }
        for metric in AssessmentMetric.allCases {
            if measured.contains(metric) && listed.contains(metric) { issues.append("unavailableMetrics must not list measured metric \(metric.rawValue)") }
            if !measured.contains(metric) && !listed.contains(metric) { issues.append("unavailableMetrics must explain null metric \(metric.rawValue)") }
        }

        validateWords(wordAccuracy: scores.wordAccuracy, wordAccuracyUnavailable: listed.contains(.wordAccuracy), recordingDurationMs: recordingDurationMs, into: &issues)
    }

    private nonisolated func validateWords(wordAccuracy: Double?, wordAccuracyUnavailable: Bool, recordingDurationMs: Int?, into issues: inout [String]) {
        if wordResults.isEmpty {
            if !wordAccuracyUnavailable { issues.append("wordResults may be empty only when wordAccuracy is unavailable") }
            return
        }
        if wordAccuracyUnavailable { issues.append("wordAccuracy must be measured when an alignment is present") }

        var nextReference = 0
        var errors = 0
        for (index, word) in wordResults.enumerated() {
            let path = "wordResults[\(index)]"
            if word.textStatus != .matched { errors += 1 }

            if word.textStatus == .inserted {
                if word.referenceWordIndex != nil || word.expected != nil || word.recognized?.isEmpty != false {
                    issues.append("\(path): an insertion needs a recognized token and no reference index or expected token")
                }
            } else {
                if word.referenceWordIndex != nextReference { issues.append("\(path).referenceWordIndex must be \(nextReference): each reference token appears once, in order") }
                nextReference += 1
                if word.expected?.isEmpty != false { issues.append("\(path).expected must be a non-empty string") }
                if word.textStatus == .omitted && word.recognized != nil { issues.append("\(path).recognized must be null for an omission") }
                if word.textStatus != .omitted && word.recognized?.isEmpty != false { issues.append("\(path).recognized must be a non-empty string") }
            }

            if let score = word.pronunciationScore {
                if !(score.isFinite && (0...100).contains(score)) { issues.append("\(path).pronunciationScore must be null or a number from 0 through 100") }
                if word.pronunciationUnavailableReason != nil { issues.append("\(path).pronunciationUnavailableReason must be absent when pronunciationScore is present") }
                if word.textStatus == .omitted { issues.append("\(path).pronunciationScore must be null for an omission") }
            } else if word.pronunciationUnavailableReason == nil {
                issues.append("\(path).pronunciationUnavailableReason is required when pronunciationScore is null")
            }
            if word.textStatus == .omitted && word.pronunciationUnavailableReason != .omittedWord { issues.append("\(path).pronunciationUnavailableReason must be omitted_word for an omission") }

            switch (word.startMs, word.endMs) {
            case (nil, nil):
                if word.textStatus != .omitted { issues.append("\(path): a measured word needs boundaries") }
            case let (start?, end?):
                if word.textStatus == .omitted {
                    issues.append("\(path): an omission has null boundaries")
                } else if start < 0 || start >= end {
                    issues.append("\(path): boundaries must satisfy 0 <= startMs < endMs")
                } else if let recordingDurationMs, end > recordingDurationMs {
                    issues.append("\(path): endMs exceeds the recording duration")
                }
            default:
                issues.append("\(path): startMs and endMs must both be null or both be integers")
            }
        }

        if let wordAccuracy, nextReference > 0 {
            let exact = 100 * max(0, 1 - Double(errors) / Double(nextReference))
            if wordAccuracy != (exact + 0.5 + 1e-9).rounded(.down) { issues.append("scores.wordAccuracy does not match the substitutions, omissions and insertions in wordResults") }
        }
    }

    private nonisolated func validateCoaching(into issues: inout [String]) {
        if coaching.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("coaching.summary must be a non-empty string") }
        if coaching.strengths.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { issues.append("coaching.strengths must hold non-empty strings") }
        if coaching.focus.count > 3 { issues.append("coaching.focus may hold at most three suggestions") }
        let referenceCount = wordResults.filter { $0.textStatus != .inserted }.count
        for (index, item) in coaching.focus.enumerated() {
            let path = "coaching.focus[\(index)]"
            if let wordIndex = item.referenceWordIndex, wordIndex < 0 || (referenceCount > 0 && wordIndex >= referenceCount) {
                issues.append("\(path).referenceWordIndex must be null or a valid reference index")
            }
            if item.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("\(path).instruction must be a non-empty string") }
            if item.practiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("\(path).practiceText must be a non-empty string") }
        }
    }
}
