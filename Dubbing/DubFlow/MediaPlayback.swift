import AVFoundation
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

@MainActor
final class TakeRecorder {
    private var recorder: AVAudioRecorder?

    func start(writingTo url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        try MediaPipeline.prepareOutput(url)
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record() else { throw DubFlowError.recordingFailed(url.lastPathComponent) }
        self.recorder = recorder
    }

    /// Stops recording and returns the recorded length in seconds.
    func stop() -> Double {
        let duration = recorder?.currentTime ?? 0
        recorder?.stop()
        recorder = nil
        return duration
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

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerContainerView, context: Context) {
        view.playerLayer.player = player
    }
}

final class PlayerContainerView: UIView {
    let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
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
