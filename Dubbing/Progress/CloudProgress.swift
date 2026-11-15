import Foundation
import Observation

/// One cloud progress series, reduced to what the series may honestly show. Series that differ in
/// locale, rubric or evaluator are never merged, so each one gets its own summary.
struct CloudSeriesSummary: Equatable, Identifiable {
    struct Skill: Equatable {
        let metric: ScoreMetric
        let latest: Int
        /// Nil until the backend has enough history to call a change.
        let change: String?
    }

    struct Unmeasured: Equatable {
        let metric: ScoreMetric
        let reason: String
    }

    struct Word: Equatable {
        let word: String
        let detail: String
    }

    let id: String
    let localeName: String
    let isAcoustic: Bool
    let volume: ProgressVolume
    let skills: [Skill]
    let unmeasured: [Unmeasured]
    let words: [Word]

    init(_ series: ProgressSeries) {
        id = [series.locale, series.rubricVersion, series.evaluator.provider, series.evaluator.configVersion].joined(separator: "|")
        localeName = Locale.current.localizedString(forIdentifier: series.locale) ?? series.locale
        isAcoustic = series.canShow(.pronunciation)
        volume = series.volume
        skills = series.skills.compactMap { trend in
            guard let metric = ScoreMetric(rawValue: trend.metric), series.canShow(metric), let latest = trend.latest else { return nil }
            return Skill(metric: metric, latest: Int(latest.value.rounded()), change: Self.changeText(for: trend))
        }
        unmeasured = ScoreMetric.allCases.filter { !series.canShow($0) }.map { metric in
            let reported = series.unavailableMetrics.first { $0.metric == metric.rawValue }?.reason
            return Unmeasured(metric: metric, reason: reported ?? "Needs an acoustic speech measurement")
        }
        words = series.words.prefix(5).compactMap { word in
            if let score = series.shownPronunciationScore(for: word) {
                return Word(word: word.word, detail: "Pronunciation score \(Int(score.rounded()))")
            }
            guard word.scriptIssueCount > 0 else { return nil }
            return Word(word: word.word, detail: "Differed from the script \(word.scriptIssueCount) \(word.scriptIssueCount == 1 ? "time" : "times")")
        }
    }

    private static func changeText(for trend: SkillTrend) -> String? {
        guard let change = trend.change else { return nil }
        switch trend.direction {
        case .improving: return "Up \(Int(abs(change).rounded())) since your first measured attempt"
        case .declining: return "Down \(Int(abs(change).rounded())) since your first measured attempt"
        case .steady: return "Steady"
        case .insufficientHistory, .other: return nil
        }
    }
}

extension ScoreMetric {
    var title: String {
        switch self {
        case .languageOverall: "Overall"
        case .pronunciation: "Pronunciation"
        case .wordAccuracy: "Word accuracy"
        case .fluency: "Fluency"
        case .timingFit: "Timing"
        }
    }
}

/// The signed-in learner's progress from the coach backend.
@Observable
final class CloudProgressModel {
    enum State {
        case loading
        case loaded([CloudSeriesSummary])
        case failed(String)
    }

    private(set) var state: State = .loading
    private let account: AccountModel
    private let load: () async throws -> CoachProgress

    init(account: AccountModel, load: (() async throws -> CoachProgress)? = nil) {
        self.account = account
        self.load = load ?? {
            try await CoachBackendClient.configured(in: .main, tokens: AccountTokenProvider(account: account)).progress(locale: nil)
        }
    }

    func refresh() async {
        guard account.phase.isSignedIn else { return }
        state = .loading
        do {
            state = .loaded(try await load().series.map(CloudSeriesSummary.init))
        } catch is CancellationError {
            return
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
