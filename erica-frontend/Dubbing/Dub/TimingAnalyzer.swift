import Foundation

enum TimingVerdict: Hashable {
    case noSpeech
    case early
    case late
    case long
    case short
    case onCue
}

/// How a take's voiced span lines up with the original line, measured from the recording.
enum TimingAssessment: Hashable {
    case noSpeech
    /// Seconds relative to the original line: positive means after it, negative before it.
    case measured(onsetDelta: Double, endDelta: Double)

    static let onsetTolerance = 0.25
    static let longTolerance = 0.45
    static let shortTolerance = 0.6

    var verdict: TimingVerdict {
        switch self {
        case .noSpeech:
            return .noSpeech
        case .measured(let onset, let end):
            if onset < -Self.onsetTolerance { return .early }
            if onset > Self.onsetTolerance { return .late }
            if end > Self.longTolerance { return .long }
            if end < -Self.shortTolerance { return .short }
            return .onCue
        }
    }

    /// 0–100 timing match. A small grace window keeps natural variation from costing points.
    var score: Int? {
        guard case .measured(let onset, let end) = self else { return nil }
        let onsetPenalty = max(0, abs(onset) - 0.12)
        let endPenalty = max(0, abs(end) - 0.25)
        let raw = 100 - 70 * onsetPenalty - 35 * endPenalty
        return Int(min(100, max(0, raw)).rounded())
    }
}

enum TimingAnalyzer {
    /// Ignore takes whose loudest moment is below this RMS level: nothing was said.
    static let minimumPeak: Float = 0.01

    /// The span of a take where the voice is clearly above the room. The threshold rides on the
    /// take's own noise floor, so speaker bleed from the scene's music doesn't count as speech.
    static func voicedSpan(in envelope: Envelope) -> ClosedRange<Double>? {
        let values = envelope.values
        guard let peak = values.max(), peak >= minimumPeak else { return nil }
        let floor = values.sorted()[values.count / 5]
        guard peak - floor >= minimumPeak / 2 else { return nil }
        let threshold = floor + (peak - floor) * 0.3
        guard let first = values.firstIndex(where: { $0 >= threshold }),
              let last = values.lastIndex(where: { $0 >= threshold })
        else { return nil }
        return Double(first) * envelope.binDuration...Double(last + 1) * envelope.binDuration
    }

    static func assess(take envelope: Envelope, takeSceneStart: Double, lineStart: Double, lineEnd: Double) -> TimingAssessment {
        guard let span = voicedSpan(in: envelope) else { return .noSpeech }
        return .measured(
            onsetDelta: takeSceneStart + span.lowerBound - lineStart,
            endDelta: takeSceneStart + span.upperBound - lineEnd
        )
    }
}

/// What the character's coach persona says about a take, derived only from measured timing.
enum CoachScript {
    static func message(for assessment: TimingAssessment, line: ScriptLine) -> String {
        let cue = cueWord(in: line.text)
        switch assessment {
        case .noSpeech:
            return "I didn't hear you. Move closer to the mic and come in when the line lights up."
        case .measured(let onset, let end):
            switch assessment.verdict {
            case .early:
                return "You jumped in \(seconds(onset)) early. Wait for my mouth to move, then hit “\(cue)”."
            case .late:
                return "You came in \(seconds(onset)) late. Be ready on “\(cue)” the moment the line lights up."
            case .long:
                return "You ran \(seconds(end)) long. Keep that energy, but tighten the pace to finish with me."
            case .short:
                return "You finished \(seconds(end)) early. Give the words more room to breathe."
            case .onCue, .noSpeech:
                return "Your timing landed right on mine. Keep it, or go again and push the emotion further."
            }
        }
    }

    static func verdictLabel(for assessment: TimingAssessment) -> String {
        switch assessment {
        case .noSpeech:
            return "No voice detected"
        case .measured(let onset, let end):
            switch assessment.verdict {
            case .early: return "\(seconds(onset)) early"
            case .late: return "\(seconds(onset)) late"
            case .long: return "\(seconds(end)) long"
            case .short: return "\(seconds(end)) short"
            case .onCue, .noSpeech: return "On cue"
            }
        }
    }

    private static func seconds(_ delta: Double) -> String {
        String(format: "%.1fs", abs(delta))
    }

    private static func cueWord(in text: String) -> String {
        let word = text.split(separator: " ").first.map(String.init) ?? text
        return word.trimmingCharacters(in: .punctuationCharacters)
    }
}
