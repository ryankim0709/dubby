import AVFoundation
import os
import SwiftUI
import UIKit

/// Sleeps for `duration`; returns false if the task was cancelled instead.
nonisolated func pause(for duration: Duration) async -> Bool {
    do {
        try await Task.sleep(for: duration)
        return true
    } catch is CancellationError {
        return false
    } catch {
        preconditionFailure("Task.sleep threw something other than cancellation: \(error)")
    }
}

/// Plays exact time ranges of a clip, for previews, line cues, and recording along with the video.
@MainActor
@Observable
final class SegmentPlayer {
    let player: AVPlayer
    private(set) var isPlaying = false
    private(set) var currentSeconds: Double = 0

    init(url: URL) {
        player = AVPlayer(url: url)
    }

    func seek(to seconds: Double) async {
        await player.seek(to: mediaTime(seconds), toleranceBefore: .zero, toleranceAfter: .zero)
        currentSeconds = seconds
    }

    /// Plays from the current position until `end`. Returns true if it got there, false if stopped or cancelled.
    /// It doesn't pause at the end, so the caller can keep playing seamlessly at a different volume.
    func play(until end: Double, volume: Float) async -> Bool {
        player.volume = volume
        player.play()
        isPlaying = true
        while isPlaying {
            currentSeconds = player.currentTime().seconds
            if currentSeconds >= end { return true }
            guard await pause(for: .milliseconds(25)) else { break }
        }
        return false
    }

    func stop() {
        isPlaying = false
        player.pause()
    }
}

/// Records one take to an AAC file, from the microphone or, in DEBUG and QA builds launched with
/// `-DUBBY_AUDIO_FIXTURE <name>`, from a bundled audio file played in at real time through the same path.
/// The caller requests microphone permission either way, so a denial fails the same way with a fixture.
@MainActor
final class TakeRecorder {
    let inputSource: TakeInputSource
    private let fixtureURL: URL?
    private var recorder: AVAudioRecorder?
    private var fixture: FixtureFeed?

    /// Records from this process's configured input.
    init() {
        inputSource = TakeInputSource.configured
        fixtureURL = nil
    }

    /// Records from an audio file at real time, as `-DUBBY_AUDIO_FIXTURE` does with a bundled one.
    init(fixtureNamed name: String, url: URL) {
        inputSource = .fixture(name: name)
        fixtureURL = url
    }

    func start(writingTo url: URL) throws {
        try MediaPipeline.prepareOutput(url)
        switch inputSource {
        case .microphone:
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else { throw DubFlowError.recordingFailed(url.lastPathComponent) }
            self.recorder = recorder
        case .fixture(let name):
            guard let source = fixtureURL ?? TakeInputSource.bundledFixtureURL(named: name, in: .main) else {
                throw DubFlowError.audioFixtureMissing(name)
            }
            fixture = try FixtureFeed(source: source, output: url)
        }
    }

    /// Stops recording and returns the recorded length in seconds. A fixture that failed to write is logged and
    /// its take ends where writing stopped; `finish()` reports that failure instead.
    func stop() -> Double {
        do {
            return try finish()
        } catch {
            Self.logger.warning("Fixture input stopped early: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// Stops recording and returns the recorded length in seconds, or throws if the take couldn't be written.
    func finish() throws -> Double {
        if let fixture {
            self.fixture = nil
            return try fixture.finish()
        }
        let duration = recorder?.currentTime ?? 0
        recorder?.stop()
        recorder = nil
        return duration
    }

    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "takeRecorder")
}

/// Copies an audio file into a take at the pace of a real recording: after `t` seconds the take holds `t` seconds
/// of audio. Once the source runs out the take continues with silence, like a microphone in a quiet room.
@MainActor
private final class FixtureFeed {
    private let source: AVAudioFile
    private let output: AVAudioFile
    private let started = ContinuousClock.now
    private var written: AVAudioFramePosition = 0
    private var pump: Task<Void, Never>?
    private var failure: (any Error)?

    init(source url: URL, output outputURL: URL) throws {
        source = try AVAudioFile(forReading: url)
        let format = source.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        output = try AVAudioFile(forWriting: outputURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        pump = Task { [weak self] in
            while await pause(for: .milliseconds(50)) {
                guard let self, self.catchUp() else { return }
            }
        }
    }

    /// Writes everything due by now and closes the take. Returns its length in seconds.
    func finish() throws -> Double {
        pump?.cancel()
        pump = nil
        _ = catchUp()
        output.close()
        if let failure { throw failure }
        return Double(written) / output.processingFormat.sampleRate
    }

    /// Writes the frames due since the last call. Returns false once writing has failed, which ends the take early.
    private func catchUp() -> Bool {
        guard failure == nil else { return false }
        let format = output.processingFormat
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let due = AVAudioFramePosition(seconds * format.sampleRate) - written
        guard due > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(due)) else { return true }
        do {
            let remaining = max(0, source.length - source.framePosition)
            if remaining > 0 {
                try source.read(into: buffer, frameCount: AVAudioFrameCount(min(due, remaining)))
            }
            if buffer.frameLength < AVAudioFrameCount(due), let channels = buffer.floatChannelData {
                let filled = Int(buffer.frameLength)
                for channel in 0..<Int(format.channelCount) {
                    (channels[channel] + filled).update(repeating: 0, count: Int(due) - filled)
                }
                buffer.frameLength = AVAudioFrameCount(due)
            }
            try output.write(from: buffer)
            written += AVAudioFramePosition(buffer.frameLength)
            return true
        } catch {
            failure = error
            return false
        }
    }
}

@MainActor
final class TakePlayer {
    private var player: AVAudioPlayer?

    func start(url: URL) throws {
        let player = try AVAudioPlayer(contentsOf: url)
        guard player.play() else { throw DubFlowError.playbackFailed(url.lastPathComponent) }
        self.player = player
    }

    func stop() {
        player?.stop()
        player = nil
    }
}

nonisolated enum StudioAudioSession {
    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
    }

    /// Lets other apps' audio resume once the studio is done with the microphone and speaker.
    static func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// A bare video surface with no system controls, so the flow can drive playback itself.
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity

    init(player: AVPlayer) {
        self.init(player: player, gravity: .resizeAspect)
    }

    init(player: AVPlayer, gravity: AVLayerVideoGravity) {
        self.player = player
        self.gravity = gravity
    }

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateUIView(_ view: PlayerContainerView, context: Context) {
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
    }
}

final class PlayerContainerView: UIView {
    let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
