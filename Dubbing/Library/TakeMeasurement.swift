import Accelerate
import Foundation
import os

/// How loudly the microphone picked up a take, judged from its peak level.
nonisolated enum InputLevel: String, Codable, Hashable, Sendable {
    /// Nothing but noise floor: the microphone heard no voice.
    case silent
    case quiet
    case clear

    /// Peaks below these dBFS values are silence and quiet speech. They are plain level checks, not speech detection.
    static let silentBelow = -50.0
    static let quietBelow = -24.0

    init(peakDecibels: Double) {
        if peakDecibels < Self.silentBelow {
            self = .silent
        } else if peakDecibels < Self.quietBelow {
            self = .quiet
        } else {
            self = .clear
        }
    }
}

/// What the app measured about one recorded take. Pronunciation, word accuracy, and fluency are not here
/// because nothing measures them yet; the UI says so instead of showing a number.
nonisolated struct TakeMeasurement: Codable, Hashable, Sendable {
    let lineID: Int
    /// Length of the recording, in seconds.
    let takeSeconds: Double
    /// Length of the original line, in seconds.
    let lineSeconds: Double
    /// How long the take may run before the export cuts it (see `ScriptBuilder.allowedTakeDuration`).
    let allowedSeconds: Double
    /// Loudest sample in the recording, in dBFS, or nil when the audio file couldn't be read.
    let peakDecibels: Double?

    var level: InputLevel? { peakDecibels.map(InputLevel.init(peakDecibels:)) }

    /// Seconds the export will cut from the end of this take, when that is enough to notice.
    var overrunSeconds: Double? {
        let overrun = takeSeconds - allowedSeconds
        return overrun > DubTiming.noticeableTrim ? overrun : nil
    }

    var fitsLine: Bool { overrunSeconds == nil }
}

/// Measures real recordings. Reading the audio is the only I/O, and a failure is kept visible as a nil peak.
nonisolated enum TakeMeasuring {
    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "measurement")
    /// Floor for silence, since log10(0) isn't a number a JSON file can hold.
    private static let floorDecibels = -120.0

    @concurrent
    static func measure(take: RecordedTake, line: ScriptLine, lines: [ScriptLine], sectionDuration: Double) async -> TakeMeasurement {
        let peak: Double?
        do {
            peak = peakDecibels(of: try MediaPipeline.readMonoAudio(from: take.url).samples)
        } catch {
            logger.warning("Couldn't read take audio for line \(line.id): \(error.localizedDescription, privacy: .public)")
            peak = nil
        }
        return TakeMeasurement(
            lineID: line.id,
            takeSeconds: take.duration,
            lineSeconds: line.duration,
            allowedSeconds: ScriptBuilder.allowedTakeDuration(for: line, in: lines, sectionDuration: sectionDuration, grace: DubTiming.lineGrace),
            peakDecibels: peak
        )
    }

    static func peakDecibels(of samples: [Float]) -> Double {
        guard !samples.isEmpty else { return floorDecibels }
        let peak = Double(vDSP.maximumMagnitude(samples))
        return peak > 0 ? max(20 * log10(peak), floorDecibels) : floorDecibels
    }
}
