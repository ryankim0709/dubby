import Foundation
import Observation

/// What the learner is told about where a piece of feedback came from.
nonisolated struct FeedbackBasisDisplay: Equatable, Sendable {
    let basis: FeedbackBasis
    let title: String
    let detail: String
    let systemImage: String
}

nonisolated extension FeedbackBasis {
    /// The basis the app will stand behind: an acoustic claim has to point at a recorded result,
    /// so without one the feedback is shown as having no measured basis.
    func effective(citedEvidenceCount: Int) -> FeedbackBasis {
        self == .acoustic && citedEvidenceCount == 0 ? FeedbackBasis.none : self
    }

    /// The label for feedback with this basis, or nil when the feedback has no measured basis to
    /// name. Script agreement is never worded as a pronunciation score, and an acoustic claim with
    /// no cited result is not labelled as measured.
    func display(citedEvidenceCount: Int) -> FeedbackBasisDisplay? {
        guard effective(citedEvidenceCount: citedEvidenceCount) != .none else { return nil }
        let evidence = citedEvidenceCount > 0 ? " It cites \(citedEvidenceCount) of your recorded results." : ""
        switch self {
        case .acoustic:
            return FeedbackBasisDisplay(
                basis: .acoustic,
                title: "Measured from your voice",
                detail: "This feedback comes from an acoustic pronunciation measurement of your recording.\(evidence)",
                systemImage: "waveform"
            )
        case .scriptAgreement:
            return FeedbackBasisDisplay(
                basis: .scriptAgreement,
                title: "Compared with the script",
                detail: "This feedback checks which words you said against the script. It isn't a pronunciation score.\(evidence)",
                systemImage: "text.alignleft"
            )
        case .none:
            return nil
        }
    }
}

nonisolated extension ExerciseKind {
    var title: String {
        switch self {
        case .drillWord: "Practise one word"
        case .retryLine: "Retry a line"
        case .newLine: "Try a new line"
        case .firstAttempt: "Start with a first attempt"
        }
    }
}

nonisolated extension PracticeFocus {
    var title: String {
        switch self {
        case .any: "Anything"
        case .pronunciation: "Pronunciation"
        case .wordAccuracy: "Saying the right words"
        case .fluency: "Fluency"
        case .timing: "Timing"
        }
    }
}

nonisolated extension CoachPreferences {
    /// Adds or removes one line from the lines the coach should not suggest.
    mutating func setAvoiding(lineID: String, isAvoiding: Bool) {
        avoidLineIds.removeAll { $0 == lineID }
        if isAvoiding && canAvoidMoreLines { avoidLineIds.append(lineID) }
    }
}

nonisolated extension PracticeChallenge {
    var title: String {
        switch self {
        case .gentle: "Gentle"
        case .standard: "Standard"
        case .stretch: "Stretch"
        }
    }
}

nonisolated extension MemoryItemKind {
    var title: String {
        switch self {
        case .preference: "Preference"
        case .attemptNote: "Practice note"
        case .difficulty: "Trouble spot"
        case .other: "Note"
        }
    }
}

nonisolated extension ProgressSeries {
    /// Whether this series may show a number for `metric`. Pronunciation and fluency need an
    /// acoustic measurement, so a transcript-only series never shows them, and a metric the series
    /// lists as unavailable is never shown as zero.
    func canShow(_ metric: ScoreMetric) -> Bool {
        if unavailableMetrics.contains(where: { $0.metric == metric.rawValue }) { return false }
        switch metric {
        case .pronunciation, .fluency: return evaluator.measurement == .acoustic && pronunciationBasis == .acoustic
        case .languageOverall, .wordAccuracy, .timingFit: return true
        }
    }

    /// A word's latest measured pronunciation score, or nil unless the series is acoustic.
    func shownPronunciationScore(for word: DifficultWord) -> Double? {
        canShow(.pronunciation) && word.pronunciationIssueCount > 0 ? word.latestPronunciationScore : nil
    }
}

nonisolated extension NextExercise {
    /// Which line and attempts the exercise was chosen from, in words a learner can check.
    var evidenceSummary: String {
        guard !evidence.attemptIds.isEmpty else {
            return "You have no scored attempts to base this on yet, so this gets you started."
        }
        let shown = evidence.attemptIds.prefix(2).joined(separator: ", ")
        let hidden = evidence.attemptIds.count - 2
        let attempts = evidence.attemptIds.count == 1 ? "attempt" : "attempts"
        let list = hidden > 0 ? "\(shown) and \(hidden) more" : shown
        let line = lineId.map { " on line \($0)" } ?? ""
        return "Based on your \(attempts) \(list)\(line)."
    }
}

nonisolated extension CoachMemoryStatus {
    var storedCount: Int { pending + failed + done }

    var summary: String {
        if storedCount == 0 { return "Your coach hasn't remembered anything yet." }
        var parts = ["\(done) remembered"]
        if pending > 0 { parts.append("\(pending) saving") }
        if failed > 0 { parts.append("\(failed) couldn't be saved") }
        return "Coaching notes: " + parts.joined(separator: ", ") + "."
    }
}

/// A remote value on its way to the screen. Signed-out gets its own case because it asks the
/// learner to do something, where every other failure is only reported.
enum CoachRemoteState<Value> {
    case loading
    case loaded(Value)
    case signedOut
    case failed(String)

    /// Runs `operation` and reports its outcome. A cancelled load stays `loading` instead of
    /// flashing a failure for a screen that is already going away.
    static func result(of operation: () async throws -> Value) async -> CoachRemoteState<Value> {
        do {
            return .loaded(try await operation())
        } catch is CancellationError {
            return .loading
        } catch CoachError.signInRequired {
            return .signedOut
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Edits the learner's explicit preferences against the version the server holds.
@MainActor
@Observable
final class CoachPreferencesModel {
    enum Phase: Equatable {
        case loading
        case editing
        case saving
        case signedOut
        case failed(String)
    }

    static let conflictNotice = "Your preferences changed on another device, so the latest are shown. Check them and save again."

    private(set) var phase: Phase = .loading
    var draft = CoachPreferences.standard
    private(set) var version = 0
    private(set) var notice: String?
    private(set) var saveError: String?

    private let service: any CoachTutorService

    init(service: any CoachTutorService) {
        self.service = service
    }

    var canSave: Bool {
        phase == .editing && !draft.isGoalNoteTooLong
    }

    func load() async {
        phase = .loading
        do {
            apply(try await service.preferences())
        } catch is CancellationError {
            return
        } catch CoachError.signInRequired {
            phase = .signedOut
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Saves the draft. A version conflict reloads what the server holds instead of overwriting it.
    func save() async {
        guard canSave else { return }
        phase = .saving
        notice = nil
        saveError = nil
        do {
            apply(try await service.savePreferences(draft.trimmed, expectedVersion: version))
            notice = "Preferences saved."
        } catch is CancellationError {
            phase = .editing
        } catch CoachError.versionConflict {
            await load()
            if phase == .editing { notice = Self.conflictNotice }
        } catch CoachError.signInRequired {
            phase = .signedOut
        } catch {
            phase = .editing
            saveError = error.localizedDescription
        }
    }

    /// Picks up the memory setting and version after the memory was forgotten, which turns memory off
    /// on the server, without discarding other edits the learner hasn't saved.
    func syncMemoryMode() async {
        guard phase == .editing else { return }
        do {
            let record = try await service.preferences()
            draft.memory = record.preferences.memory
            version = record.version
        } catch is CancellationError {
            return
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func apply(_ record: CoachPreferencesRecord) {
        draft = record.preferences
        version = record.version
        phase = .editing
    }
}

/// What the coach remembers: the counts and the notes themselves.
struct CoachMemorySnapshot: Equatable {
    let status: CoachMemoryStatus
    let items: [MemoryItem]
}

/// The learner's view of their coaching memory, and the one action that erases it.
@MainActor
@Observable
final class CoachMemoryModel {
    private(set) var snapshot: CoachRemoteState<CoachMemorySnapshot> = .loading
    private(set) var isForgetting = false
    private(set) var notice: String?
    private(set) var forgetError: String?

    private let service: any CoachTutorService

    init(service: any CoachTutorService) {
        self.service = service
    }

    func load() async {
        snapshot = await CoachRemoteState.result {
            let status = try await service.memoryStatus()
            return CoachMemorySnapshot(status: status, items: try await service.memoryItems())
        }
    }

    /// Erases the memory. The backend also turns memory off, so callers refresh the preferences after.
    func forget() async {
        isForgetting = true
        notice = nil
        forgetError = nil
        defer { isForgetting = false }
        do {
            let scheduled = try await service.forgetMemory()
            notice = scheduled == 0 ? "There was nothing to forget. Memory is now off." : "Forgetting \(scheduled) coaching notes. Memory is now off; turn it back on in your preferences if you want it."
            await load()
        } catch is CancellationError {
            return
        } catch CoachError.signInRequired {
            snapshot = .signedOut
        } catch {
            forgetError = error.localizedDescription
        }
    }
}
