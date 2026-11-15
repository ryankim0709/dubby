import Foundation
import Testing
@testable import Dubbing

/// SYNTHETIC progress responses in the tutoring contract's shape; no provider or backend produced these.
@MainActor
struct CloudProgressTests {
    private static func series(measurement: String, basis: String, unavailable: String = "[]", locale: String = "es-ES") -> String {
        """
        {
          "locale": "\(locale)", "rubricVersion": "language-v1",
          "evaluator": {"provider": "synthetic", "modelVersion": null, "configVersion": "1", "measurement": "\(measurement)"},
          "pronunciationBasis": "\(basis)", "unavailableMetrics": \(unavailable),
          "volume": {"sessions": 2, "attempts": 4, "scorableAttempts": 3, "lines": 2, "practiceDays": 2, "speakingMs": 9000},
          "daily": [],
          "skills": [
            {"metric": "pronunciation", "first": {"date": "2026-11-10", "value": 60}, "latest": {"date": "2026-11-14", "value": 72.4}, "change": 12.4, "direction": "improving"},
            {"metric": "wordAccuracy", "first": null, "latest": {"date": "2026-11-14", "value": 80}, "change": null, "direction": "insufficient_history"},
            {"metric": "fluency", "first": null, "latest": null, "change": null, "direction": "insufficient_history"}
          ],
          "lines": [], "repeatedLines": [],
          "words": [
            {"word": "rapido", "status": "open", "occurrences": 3, "issueCount": 2, "issueSessions": 1, "scriptIssueCount": 1, "pronunciationIssueCount": 1, "latestPronunciationScore": 41.2, "issueAttemptIds": [], "issueAssessmentIds": [], "scriptIssueAssessmentIds": [], "pronunciationIssueAssessmentIds": []},
            {"word": "casa", "status": "open", "occurrences": 2, "issueCount": 1, "issueSessions": 1, "scriptIssueCount": 0, "pronunciationIssueCount": 0, "latestPronunciationScore": null, "issueAttemptIds": [], "issueAssessmentIds": [], "scriptIssueAssessmentIds": [], "pronunciationIssueAssessmentIds": []}
          ],
          "guidance": {"summary": "", "focusAreas": [], "retryLines": [], "newLines": []}
        }
        """
    }

    private static func progress(_ series: String...) throws -> CoachProgress {
        let json = #"{"generatedAt": "2026-11-15T00:00:00Z", "timeZonePolicy": "utc", "series": [\#(series.joined(separator: ","))]}"#
        return try JSONDecoder().decode(CoachProgress.self, from: Data(json.utf8))
    }

    @Test func anAcousticSeriesShowsItsMeasuredNumbers() throws {
        let summary = CloudSeriesSummary(try Self.progress(Self.series(measurement: "acoustic", basis: "acoustic")).series[0])

        #expect(summary.isAcoustic)
        #expect(summary.skills.map(\.metric) == [.pronunciation, .wordAccuracy])
        #expect(summary.skills[0].latest == 72)
        #expect(summary.skills[1].change == nil)
        #expect(summary.words == [.init(word: "rapido", detail: "Pronunciation score 41")])
    }

    @Test func aTranscriptOnlySeriesNeverShowsPronunciationOrFluency() throws {
        let transcript = Self.series(measurement: "transcript_only", basis: "script_agreement", unavailable: #"[{"metric": "timingFit", "reason": "no word timings"}]"#)
        let summary = CloudSeriesSummary(try Self.progress(transcript).series[0])

        #expect(!summary.isAcoustic)
        #expect(summary.skills.map(\.metric) == [.wordAccuracy])
        #expect(summary.unmeasured.map(\.metric).contains(.pronunciation))
        #expect(summary.unmeasured.first { $0.metric == .timingFit }?.reason == "no word timings")
        #expect(summary.words.first?.detail == "Differed from the script 1 time")
    }

    @Test func seriesFromDifferentLocalesStayApart() throws {
        let both = try Self.progress(Self.series(measurement: "acoustic", basis: "acoustic"), Self.series(measurement: "acoustic", basis: "acoustic", locale: "fr-FR"))
        let summaries = both.series.map(CloudSeriesSummary.init)

        #expect(summaries.count == 2)
        #expect(Set(summaries.map(\.id)).count == 2)
    }

    @Test func signedOutNeverLoadsAndFailuresAreReported() async throws {
        var calls = 0
        let signedOut = CloudProgressModel(account: AccountModel(service: nil)) {
            calls += 1
            throw CoachError.signInRequired
        }
        await signedOut.refresh()
        #expect(calls == 0)
        if case .loading = signedOut.state {} else { Issue.record("a signed-out model must stay idle") }
    }
}
