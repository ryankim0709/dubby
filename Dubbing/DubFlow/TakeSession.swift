import AVFoundation
import Foundation
import Observation
import os
import UIKit

/// Where a take's audio came from.
nonisolated enum TakeInputSource: Hashable, Sendable {
    case microphone
    /// A bundled synthetic or licensed file played in at real time (DEBUG and QA builds only). Never assessed.
    case fixture(name: String)

    static let launchArgument = "-DUBBY_AUDIO_FIXTURE"

    /// True when no person spoke this take.
    var isSynthetic: Bool {
        if case .fixture = self { true } else { false }
    }

    /// The input this process records from: the fixture named by `-DUBBY_AUDIO_FIXTURE` in DEBUG builds and builds
    /// defining `DUBBY_QA`, otherwise the microphone. Release builds ignore the argument.
    static var configured: TakeInputSource {
        #if DEBUG || DUBBY_QA
        parse(arguments: ProcessInfo.processInfo.arguments)
        #else
        .microphone
        #endif
    }

    static func parse(arguments: [String]) -> TakeInputSource {
        guard let index = arguments.firstIndex(of: launchArgument), arguments.indices.contains(index + 1) else { return .microphone }
        return .fixture(name: arguments[index + 1])
    }

    /// The bundled file for a fixture resource name, trying the audio extensions QA ships.
    static func bundledFixtureURL(named name: String, in bundle: Bundle) -> URL? {
        ["m4a", "wav", "caf"].lazy.compactMap { bundle.url(forResource: name, withExtension: $0) }.first
    }
}

/// One recording that has started and not yet ended.
nonisolated struct InFlightTake: Hashable, Sendable {
    let lineID: Int
    let url: URL
}

/// The take lifecycle for every line, as a value: at most one recording in flight, at most one candidate per line
/// waiting to be kept, and the kept take per line. Only `keepCandidate` replaces a kept take; cancelling, failing or
/// interrupting a recording, and discarding a candidate, never touch it.
nonisolated struct TakeBook: Hashable, Sendable {
    private(set) var kept: [Int: RecordedTake] = [:]
    private(set) var candidates: [Int: RecordedTake] = [:]
    private(set) var inFlight: InFlightTake?

    /// Starts a recording. Returns false when another recording is already in flight.
    mutating func begin(lineID: Int, url: URL) -> Bool {
        guard inFlight == nil else { return false }
        inFlight = InFlightTake(lineID: lineID, url: url)
        return true
    }

    /// The in-flight recording finished: it becomes its line's candidate. Returns the file of an older candidate
    /// it replaced, which nothing uses any more. Returns nil and changes nothing if `take` isn't the one in flight.
    mutating func finish(_ take: RecordedTake) -> URL? {
        guard let inFlight, inFlight.url == take.url else { return nil }
        self.inFlight = nil
        return candidates.updateValue(take, forKey: inFlight.lineID)?.url
    }

    /// The in-flight recording was cancelled, failed or interrupted. Returns its file, which must not be used.
    mutating func abandon() -> URL? {
        defer { inFlight = nil }
        return inFlight?.url
    }

    /// Keeps a line's candidate, replacing its kept take. Returns false when the line has no candidate.
    mutating func keepCandidate(lineID: Int) -> Bool {
        guard let candidate = candidates.removeValue(forKey: lineID) else { return false }
        kept[lineID] = candidate
        return true
    }

    /// Drops a line's candidate and returns its file. The kept take stays.
    mutating func discardCandidate(lineID: Int) -> URL? {
        candidates.removeValue(forKey: lineID)?.url
    }

    /// The take to show for a line: its candidate when one waits, else its kept take.
    func latestTake(lineID: Int) -> RecordedTake? {
        candidates[lineID] ?? kept[lineID]
    }
}

/// Why the system took the audio away from a recording.
nonisolated enum StudioInterruption: Hashable, Sendable {
    /// A call, Siri, an alarm or another app took the audio session.
    case audioSessionInterrupted
    /// The audio route the recording used went away, for example headphones unplugged or AirPods disconnected.
    case audioRouteLost
    /// Dubby left the foreground.
    case appBackgrounded

    var reason: String {
        switch self {
        case .audioSessionInterrupted: "a call or another app took over the audio"
        case .audioRouteLost: "your headphones were disconnected"
        case .appBackgrounded: "Dubby left the screen"
        }
    }

    /// Reads an `AVAudioSession.interruptionNotification`. Only an interruption that began stops a recording.
    init?(interruptionUserInfo userInfo: [AnyHashable: Any]) {
        guard
            let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: rawType) == .began
        else { return nil }
        self = .audioSessionInterrupted
    }

    /// Reads an `AVAudioSession.routeChangeNotification`. Only losing the current device stops a recording;
    /// connecting headphones mid-take doesn't.
    init?(routeChangeUserInfo userInfo: [AnyHashable: Any]) {
        guard
            let rawReason = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
            AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
        else { return nil }
        self = .audioRouteLost
    }
}

/// How one recording attempt ended.
nonisolated enum TakeAttemptOutcome: Equatable, Sendable {
    /// A new candidate waits for keep or discard.
    case candidate(lineID: Int)
    /// The learner cancelled; nothing was saved.
    case cancelled(lineID: Int)
    case failed(lineID: Int, error: DubFlowError)
    case interrupted(lineID: Int, StudioInterruption)
}

/// What the take session is doing right now.
nonisolated enum TakeSessionActivity: Hashable, Sendable {
    case idle
    case requestingPermission(lineID: Int)
    /// Playing the cue before the line, with the original audio.
    case cue(lineID: Int)
    /// Recording while the video rolls silently.
    case recording(lineID: Int)
}

/// Microphone permission, as a function so tests can drive a grant or a denial without the system prompt.
nonisolated struct MicrophonePermission: Sendable {
    let request: @MainActor @Sendable () async -> Bool

    static let system = MicrophonePermission { await AVAudioApplication.requestRecordPermission() }
}

/// The shared audio session, as functions so tests don't reconfigure the simulator's audio.
nonisolated struct StudioAudioControl: Sendable {
    let activate: @MainActor @Sendable () throws -> Void
    let deactivate: @MainActor @Sendable () throws -> Void

    static let system = StudioAudioControl(activate: { try StudioAudioSession.activate() }, deactivate: { try StudioAudioSession.deactivate() })
}

/// Records takes for one dub: the cue, the recording window, and the take lifecycle, with interruptions, route loss,
/// backgrounding, cancellation and microphone denial ending an attempt in a typed outcome that never replaces a
/// kept take. Views drive it and render `activity`, `book` and `lastOutcome`.
@MainActor
@Observable
final class TakeSession {
    let setup: DubSetup
    let player: SegmentPlayer
    private(set) var activity: TakeSessionActivity = .idle
    private(set) var book = TakeBook()
    private(set) var lastOutcome: TakeAttemptOutcome?

    @ObservationIgnored private let recorder: TakeRecorder
    @ObservationIgnored private let permission: MicrophonePermission
    @ObservationIgnored private let audio: StudioAudioControl
    @ObservationIgnored private var interruption: StudioInterruption?
    @ObservationIgnored private var isCancelling = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "takeSession")

    /// A session recording from this process's configured input, with the system permission prompt and audio session.
    convenience init(setup: DubSetup) {
        self.init(setup: setup, player: SegmentPlayer(url: setup.clip.url), recorder: TakeRecorder(), permission: .system, audio: .system)
    }

    init(setup: DubSetup, player: SegmentPlayer, recorder: TakeRecorder, permission: MicrophonePermission, audio: StudioAudioControl) {
        self.setup = setup
        self.player = player
        self.recorder = recorder
        self.permission = permission
        self.audio = audio
    }

    var inputSource: TakeInputSource { recorder.inputSource }

    /// Kept takes by line, what export uses.
    var keptTakes: [Int: RecordedTake] { book.kept }

    /// Starts following audio interruptions, route changes and backgrounding. Call `close()` to stop.
    func observeSystemEvents() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            // Observers on the main queue run on the main actor.
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
                guard let interruption = notification.userInfo.flatMap(StudioInterruption.init(interruptionUserInfo:)) else { return }
                MainActor.assumeIsolated { self?.interrupt(interruption) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
                guard let interruption = notification.userInfo.flatMap(StudioInterruption.init(routeChangeUserInfo:)) else { return }
                MainActor.assumeIsolated { self?.interrupt(interruption) }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.interrupt(.appBackgrounded) }
            },
        ]
    }

    /// Plays the cue, then records `line` across its recording window while the video rolls silently, and returns
    /// when the attempt has ended. The take starts exactly at the line start, which is where export places it.
    /// Does nothing if an attempt is already running.
    func record(_ line: ScriptLine) async {
        guard activity == .idle else { return }
        let timing = setup.timing(for: line)
        let offset = setup.section.start
        let url = setup.clip.workingDirectory.appending(path: "take-\(line.id)-\(UUID().uuidString).m4a")
        interruption = nil
        isCancelling = false
        activity = .requestingPermission(lineID: line.id)
        lastOutcome = await attempt(line: line, timing: timing, offset: offset, url: url)
        player.stop()
        activity = .idle
    }

    private func attempt(line: ScriptLine, timing: LineTiming, offset: Double, url: URL) async -> TakeAttemptOutcome {
        do {
            guard await permission.request() else { throw DubFlowError.microphoneDenied }
            if let ended = endedEarly(lineID: line.id) { return ended }
            try audio.activate()
            activity = .cue(lineID: line.id)
            await player.seek(to: offset + timing.cueStart)
            if timing.cueStart < timing.line.start {
                _ = await player.play(until: offset + timing.line.start, volume: 1)
            }
            if let ended = endedEarly(lineID: line.id) { return ended }
            guard book.begin(lineID: line.id, url: url) else { return .failed(lineID: line.id, error: .recordingFailed(url.lastPathComponent)) }
            try recorder.start(writingTo: url)
            activity = .recording(lineID: line.id)
            _ = await player.play(until: offset + timing.recordingWindow.end, volume: 0)
            let duration = try recorder.finish()
            if let ended = endedEarly(lineID: line.id) {
                discard(book.abandon())
                return ended
            }
            discard(book.finish(RecordedTake(url: url, duration: duration, inputSource: recorder.inputSource)))
            return .candidate(lineID: line.id)
        } catch {
            do {
                _ = try recorder.finish()
            } catch {
                Self.logger.warning("Recorder didn't close cleanly: \(error.localizedDescription, privacy: .public)")
            }
            discard(book.abandon())
            if let ended = endedEarly(lineID: line.id) { return ended }
            if let flowError = error as? DubFlowError { return .failed(lineID: line.id, error: flowError) }
            Self.logger.warning("Recording failed: \(error.localizedDescription, privacy: .public)")
            return .failed(lineID: line.id, error: .recordingFailed(url.lastPathComponent))
        }
    }

    /// An interruption, a cancel, or task cancellation ends the attempt without a take, in that order of precedence.
    private func endedEarly(lineID: Int) -> TakeAttemptOutcome? {
        if let interruption { return .interrupted(lineID: lineID, interruption) }
        if isCancelling || Task.isCancelled { return .cancelled(lineID: lineID) }
        return nil
    }

    /// Ends the recording now and keeps what was recorded as a candidate.
    func stopRecording() {
        guard case .recording = activity else { return }
        player.stop()
    }

    /// Ends the attempt without a take. A kept take and any candidate stay.
    func cancelRecording() {
        guard activity != .idle else { return }
        isCancelling = true
        player.stop()
    }

    /// Ends the attempt because the system took the audio away. A kept take and any candidate stay.
    func interrupt(_ reason: StudioInterruption) {
        guard activity != .idle else { return }
        interruption = reason
        player.stop()
    }

    /// Keeps the line's candidate, replacing its kept take.
    func keepCandidate(lineID: Int) {
        _ = book.keepCandidate(lineID: lineID)
    }

    /// Drops the line's candidate; the kept take stays.
    func discardCandidate(lineID: Int) {
        discard(book.discardCandidate(lineID: lineID))
    }

    /// Stops playback and capture, stops following system events, and releases the audio session. Kept takes stay on disk.
    func close() {
        if activity != .idle { cancelRecording() }
        player.stop()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        do {
            try audio.deactivate()
        } catch {
            Self.logger.warning("Audio session deactivation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes a take file that no line uses.
    private func discard(_ url: URL?) {
        guard let url, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Self.logger.warning("Couldn't remove an unused take: \(error.localizedDescription, privacy: .public)")
        }
    }
}
