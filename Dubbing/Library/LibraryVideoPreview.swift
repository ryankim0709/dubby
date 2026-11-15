import AVFoundation
import SwiftUI

/// Only the visible poster plays, keeping browsing silent and releasing off-screen decoders.
struct LibraryVideoPreview: View {
    let clip: LibraryClip
    let isActive: Bool
    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?
    @State private var failure: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var shouldPlay: Bool { isActive && !reduceMotion && scenePhase == .active }

    var body: some View {
        VideoThumbnail(url: clip.url)
            .overlay {
                if shouldPlay, looper != nil {
                    PlayerSurface(player: player, gravity: .resizeAspectFill)
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
                    try Task.checkCancellation()
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
