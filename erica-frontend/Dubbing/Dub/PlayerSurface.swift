import AVFoundation
import Observation
import SwiftUI
import UIKit

/// A bare video layer: the app draws its own controls, so AVKit's chrome stays out of the frame.
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> PlayerLayerView {
        PlayerLayerView()
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
    }
}

final class PlayerLayerView: UIView {
    let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        // Display only: drags and taps go to the scroll view or button around the video.
        isUserInteractionEnabled = false
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("PlayerLayerView is only created in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

/// A looping clip for previews, the Discover hero, and the feed.
@Observable
final class LoopingClip {
    let player = AVQueuePlayer()
    private(set) var loadError: Error?
    @ObservationIgnored private var looper: AVPlayerLooper?

    isolated deinit {
        player.pause()
    }

    /// Browse surfaces are picture-only: the clip loops silently, and sound lives only in the studio.
    func loadPicture(of scene: SceneClip, seconds: Double) {
        do {
            let asset = AVURLAsset(url: try MediaLibrary.url(for: scene.media.video))
            player.isMuted = true
            let length = min(seconds, scene.duration)
            start(asset: asset, range: CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 600)))
        } catch {
            loadError = error
        }
    }

    private func start(asset: AVAsset, range: CMTimeRange) {
        let item = AVPlayerItem(asset: asset)
        looper = AVPlayerLooper(player: player, templateItem: item, timeRange: range)
    }
}
