import AVFoundation
import SwiftUI
import UIKit

/// Only the visible poster plays, keeping browsing silent and releasing off-screen decoders.
struct LibraryVideoPreview: View {
    let clip: LibraryClip
    let isActive: Bool
    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?
    @State private var failure: String?
    @State private var picture: VideoPicture?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var shouldPlay: Bool { isActive && !reduceMotion && scenePhase == .active }

    var body: some View {
        VideoThumbnail(url: clip.url)
            .overlay {
                if shouldPlay, looper != nil, let picture {
                    ScenePreviewSurface(player: player, picture: picture)
                }
            }
            .overlay(alignment: .topLeading) {
                if let failure {
                    Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                        .dubFont(13, weight: .medium)
                        .foregroundStyle(Palette.textPrimary)
                        .padding(10)
                        .background(.black.opacity(0.55))
                        .accessibilityHint(failure)
                }
            }
            .clipped()
            .task(id: shouldPlay) {
                guard shouldPlay else {
                    stop()
                    return
                }
                do {
                    let asset = AVURLAsset(url: clip.url)
                    guard try await asset.load(.isPlayable) else { throw DubFlowError.unsupportedVideo }
                    let picture = try await MediaPipeline.previewPicture(for: clip.url)
                    try Task.checkCancellation()
                    self.picture = picture
                    failure = nil
                    player.isMuted = true
                    looper = AVPlayerLooper(
                        player: player,
                        templateItem: AVPlayerItem(asset: asset),
                        timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: min(10, clip.durationSeconds), preferredTimescale: 600))
                    )
                    player.play()
                } catch is CancellationError {
                    stop()
                } catch {
                    failure = error.localizedDescription
                    stop()
                }
            }
            .onDisappear { stop() }
    }

    private func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}

struct ScenePreviewSurface: UIViewRepresentable {
    let player: AVPlayer
    let picture: VideoPicture

    func makeUIView(context: Context) -> ScenePreviewLayerView {
        ScenePreviewLayerView(picture: picture)
    }

    func updateUIView(_ view: ScenePreviewLayerView, context: Context) {
        view.playerLayer.player = player
        view.picture = picture
        view.setNeedsLayout()
    }

    static func dismantleUIView(_ view: ScenePreviewLayerView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

final class ScenePreviewLayerView: UIView {
    let playerLayer = AVPlayerLayer()
    var picture: VideoPicture

    init(picture: VideoPicture) {
        self.picture = picture
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("ScenePreviewLayerView is only created in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = picture.playerFrame(in: bounds)
    }
}
