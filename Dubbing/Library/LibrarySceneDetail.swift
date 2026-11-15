import AVKit
import SwiftUI

struct LibrarySceneDetail: View {
    let clip: LibraryClip
    let onDub: () -> Void
    let onClose: () -> Void
    @State private var playback: ScenePreviewPlayback
    @State private var picture: LoadState<VideoPicture> = .loading
    @State private var isVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    init(clip: LibraryClip, onDub: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.clip = clip
        self.onDub = onDub
        self.onClose = onClose
        _playback = State(initialValue: ScenePreviewPlayback(url: clip.url))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                    .aspectRatio(4 / 5, contentMode: .fit)
                    .overlay {
                        LinearGradient(colors: [.clear, Palette.background], startPoint: .center, endPoint: .bottom)
                    }
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 12) {
                            MetaPill(text: clip.durationSeconds.preciseClockString, systemImage: "film")
                            Text(clip.title)
                                .dubFont(32, weight: .bold)
                                .foregroundStyle(Palette.textPrimary)
                        }
                        .padding(20)
                    }
                VStack(alignment: .leading, spacing: 22) {
                    Text("A scene. A character. Your voice.")
                        .dubFont(22, weight: .bold)
                    Text("Choose up to 30 seconds of dialogue, pick who you'll play, and record their lines. Your finished dub is saved to Shelf.")
                        .dubFont(17, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .foregroundStyle(Palette.textPrimary)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close scene", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("closeLibraryScene")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Dub this scene", action: onDub)
                .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
                .accessibilityIdentifier("dubScene-\(clip.sceneID)")
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Palette.background)
        }
        .task(id: clip.url) {
            do {
                let frame = try await MediaPipeline.previewPicture(for: clip.url)
                try Task.checkCancellation()
                picture = .loaded(frame)
                updatePlayback()
            } catch is CancellationError {
                return
            } catch {
                picture = .failed(error.localizedDescription)
            }
        }
        .onAppear {
            isVisible = true
            updatePlayback()
        }
        .onDisappear {
            isVisible = false
            playback.player.pause()
        }
        .onChange(of: scenePhase) { updatePlayback() }
        .onChange(of: reduceMotion) { updatePlayback() }
    }

    private var hero: some View {
        Palette.surface
            .overlay {
                switch picture {
                case .loading:
                    ProgressView().tint(Palette.textPrimary)
                case .loaded(let frame):
                    Image(decorative: frame.image, scale: 1)
                        .resizable()
                        .scaledToFill()
                case .failed(let message):
                    EmptyStateView(systemImage: "exclamationmark.triangle", title: "Preview unavailable", message: message)
                }
            }
            .overlay {
                if case .loaded(let frame) = picture, !reduceMotion {
                    ScenePreviewSurface(player: playback.player, picture: frame)
                        .accessibilityHidden(true)
                }
            }
            .clipped()
    }

    private func updatePlayback() {
        if case .loaded = picture, isVisible, !reduceMotion, scenePhase == .active {
            playback.player.play()
        } else {
            playback.player.pause()
        }
    }
}

private final class ScenePreviewPlayback {
    let player: AVQueuePlayer
    // The player stops looping when AVPlayerLooper is released.
    private let looper: AVPlayerLooper

    init(url: URL) {
        let player = AVQueuePlayer()
        player.isMuted = true
        self.player = player
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
    }

    isolated deinit {
        player.pause()
    }
}

private struct ScenePreviewSurface: UIViewRepresentable {
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

private final class ScenePreviewLayerView: UIView {
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
