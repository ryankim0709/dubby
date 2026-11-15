import Foundation
import os

/// How a take's voice lines up with the original line, measured on the phone from the recording. Recording starts
/// at the line's first moment and runs a little past its end, so offsets are relative to the line.
nonisolated enum TakeTiming: Equatable, Sendable {
    case noVoice
    /// The voice was already going when recording began, so the take started before the line and lost its start.
    case early
    case late(seconds: Double)
    case long(seconds: Double)
    case short(seconds: Double)
    case onCue

    static let lateTolerance = 0.25
    static let longTolerance = 0.45
    static let shortTolerance = 0.6
    /// Level bins of 20 ms: fine enough for onsets, coarse enough to smooth over single syllables.
    static let binSeconds = 0.02
    /// Below this RMS the loudest moment is room noise, not a voice.
    static let minimumPeak: Float = 0.01

    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "take-timing")

    static func assess(samples: [Float], sampleRate: Double, lineDuration: Double) -> TakeTiming {
        guard let span = voicedBins(in: levels(of: samples, sampleRate: sampleRate)) else { return .noVoice }
        // Two bins of voice at the very start means the learner was already speaking when recording began.
        if span.lowerBound < 2 { return .early }
        let onset = Double(span.lowerBound) * binSeconds
        let end = Double(span.upperBound + 1) * binSeconds - lineDuration
        if onset > lateTolerance { return .late(seconds: onset) }
        if end > longTolerance { return .long(seconds: end) }
        if end < -shortTolerance { return .short(seconds: -end) }
        return .onCue
    }

    /// Reads the take off the main actor. An unreadable file is reported as no voice, and logged.
    @concurrent
    static func measure(take: RecordedTake, lineDuration: Double) async -> TakeTiming {
        do {
            let audio = try MediaPipeline.readMonoAudio(from: take.url)
            return assess(samples: audio.samples, sampleRate: audio.sampleRate, lineDuration: lineDuration)
        } catch {
            logger.warning("Couldn't read a take to time it. error=\(error.localizedDescription, privacy: .public)")
            return .noVoice
        }
    }

    static func levels(of samples: [Float], sampleRate: Double) -> [Float] {
        let binLength = max(1, Int(sampleRate * binSeconds))
        return stride(from: 0, to: samples.count, by: binLength).map { start in
            let bin = samples[start..<min(start + binLength, samples.count)]
            return (bin.reduce(0) { $0 + $1 * $1 } / Float(bin.count)).squareRoot()
        }
    }

    /// The bins where the voice is clearly above the room. The threshold rides on the take's own noise floor, so
    /// the scene's music bleeding into the microphone doesn't count as speech.
    static func voicedBins(in levels: [Float]) -> ClosedRange<Int>? {
        guard let peak = levels.max(), peak >= minimumPeak else { return nil }
        let floor = levels.sorted()[levels.count / 5]
        guard peak - floor >= minimumPeak / 2 else { return nil }
        let threshold = floor + (peak - floor) * 0.3
        guard let first = levels.firstIndex(where: { $0 >= threshold }), let last = levels.lastIndex(where: { $0 >= threshold }) else { return nil }
        return first...last
    }

    var suggestsRetry: Bool { self != .onCue }

    /// The short readout under "Timing".
    var label: String {
        switch self {
        case .noVoice: "No voice heard"
        case .early: "Came in early"
        case .late(let seconds): "\(Self.format(seconds)) late"
        case .long(let seconds): "\(Self.format(seconds)) long"
        case .short(let seconds): "\(Self.format(seconds)) short"
        case .onCue: "On cue"
        }
    }

    /// What the character says before the live coach has listened, in its voice. `cue` is the line's first word.
    func tip(cue: String) -> String {
        switch self {
        case .noVoice: "I didn't hear you. Move closer to the mic and come in when the line lights up."
        case .early: "You came in before the line, so your first word got cut. Wait for the cue to end, then hit “\(cue)”."
        case .late(let seconds): "You came in \(Self.format(seconds)) late. Be ready on “\(cue)” the moment the line lights up."
        case .long(let seconds): "You ran \(Self.format(seconds)) long. Keep that energy, but tighten the pace to finish with me."
        case .short(let seconds): "You finished \(Self.format(seconds)) early. Give the words more room to breathe."
        case .onCue: "Your timing landed right on mine. Keep it, or go again and push the emotion further."
        }
    }

    /// The measurement as the live coach receives it.
    var note: String {
        switch self {
        case .noVoice: "No voice was detected in the recording."
        case .early: "The voice was already going when recording began, so the take probably started before the line and lost its first word."
        case .late(let seconds): "The voice started \(Self.format(seconds)) after the line starts."
        case .long(let seconds): "The voice ran \(Self.format(seconds)) past the end of the line."
        case .short(let seconds): "The voice ended \(Self.format(seconds)) before the end of the line."
        case .onCue: "The take started and ended in time with the original line."
        }
    }

    static func cueWord(in text: String) -> String {
        let word = text.split(separator: " ").first.map(String.init) ?? text
        return word.trimmingCharacters(in: .punctuationCharacters)
    }

    private static func format(_ seconds: Double) -> String {
        String(format: "%.1fs", seconds)
    }
}
