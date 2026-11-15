import Combine
import ConvexMobile
import Foundation
import Observation

/// One completed dub's score card totals from the backend's `dubs:history`, for the Progress charts.
nonisolated struct DubHistoryItem: Decodable, Hashable, Sendable {
    nonisolated struct Evaluator: Decodable, Hashable, Sendable {
        let rubricVersion: String
        let provider: String
        let configVersion: String
    }

    let clientDubId: String
    /// Epoch milliseconds.
    let capturedAt: Double
    let sceneTitle: String
    let characterName: String
    let locale: String
    let evaluator: Evaluator?
    let dubScore: Double?
    let wordAccuracy: Double?
    let timingFit: Double?
}

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

    /// One dub's score, plotted at the time it was recorded.
    struct DubPoint: Equatable, Identifiable {
        let id: String
        let date: Date
        let score: Double
    }

    /// One skill's first-try average on one practice day, the values the skill's change is measured from.
    struct SkillPoint: Equatable, Identifiable {
        let date: Date
        let metric: ScoreMetric
        let value: Double

        var id: String { "\(metric.rawValue)|\(date.timeIntervalSince1970)" }
    }

    /// The skills charted day by day: both are measured by every evaluator.
    static let chartedSkills: [ScoreMetric] = [.wordAccuracy, .timingFit]

    let id: String
    let localeName: String
    let isAcoustic: Bool
    let volume: ProgressVolume
    let skills: [Skill]
    let unmeasured: [Unmeasured]
    let words: [Word]
    let dubScores: [DubPoint]
    let dailySkills: [SkillPoint]

    /// `history` is every completed dub; only those scored by this series' evaluator are charted here.
    init(_ series: ProgressSeries, history: [DubHistoryItem]) {
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
        dubScores = history.compactMap { item in
            guard
                item.locale == series.locale,
                let evaluator = item.evaluator,
                evaluator.rubricVersion == series.rubricVersion,
                evaluator.provider == series.evaluator.provider,
                evaluator.configVersion == series.evaluator.configVersion,
                let score = item.dubScore
            else { return nil }
            return DubPoint(id: item.clientDubId, date: Date(timeIntervalSince1970: item.capturedAt / 1000), score: score)
        }
        dailySkills = series.daily.flatMap { day -> [SkillPoint] in
            guard let date = Self.day(day.date) else { return [] }
            return Self.chartedSkills.compactMap { metric in
                guard series.canShow(metric), let value = day.firstScorable.value(for: metric) else { return nil }
                return SkillPoint(date: date, metric: metric, value: value)
            }
        }
    }

    /// A practice day as the backend reports it, `yyyy-MM-dd` in the learner's own time zone.
    private static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
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
    private let loadHistory: () async throws -> [DubHistoryItem]

    init(account: AccountModel, loadHistory: (() async throws -> [DubHistoryItem])? = nil, load: (() async throws -> CoachProgress)? = nil) {
        self.account = account
        self.load = load ?? {
            try await CoachBackendClient.configured(in: .main, tokens: AccountTokenProvider(account: account)).progress(locale: nil)
        }
        self.loadHistory = loadHistory ?? { try await Self.dubHistory(account: account) }
    }

    /// The current value of the live `dubs:history` query; a build without a backend has no dubs to chart.
    private static func dubHistory(account: AccountModel) async throws -> [DubHistoryItem] {
        guard let client = account.convexClient else { return [] }
        for try await items in client.subscribe(to: "dubs:history", yielding: [DubHistoryItem].self).values {
            return items
        }
        return []
    }

    func refresh() async {
        guard account.phase.isSignedIn else { return }
        state = .loading
        do {
            let progress = try await load()
            let history = try await loadHistory()
            state = .loaded(progress.series.map { CloudSeriesSummary($0, history: history) })
        } catch is CancellationError {
            return
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

extension MetricSet where Value == MetricValue {
    func value(for metric: ScoreMetric) -> Double? {
        switch metric {
        case .languageOverall: languageOverall?.value
        case .pronunciation: pronunciation?.value
        case .wordAccuracy: wordAccuracy?.value
        case .fluency: fluency?.value
        case .timingFit: timingFit?.value
        }
    }
}
