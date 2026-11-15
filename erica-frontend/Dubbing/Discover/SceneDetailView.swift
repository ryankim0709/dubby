import AVFoundation
import SwiftUI

/// A scene opened from a specific thumbnail; `sourceID` names that thumbnail so the detail page
/// zooms out of the exact card that was tapped, even when the scene appears in several places.
struct SceneOpening: Hashable {
    let scene: SceneClip
    let sourceID: String
}

/// What a Discover thumbnail needs to open its scene with the zoom transition.
struct SceneZoom {
    let namespace: Namespace.ID
    let open: (SceneOpening) -> Void
}

extension View {
    /// Marks a thumbnail as the place a scene's detail page grows out of and shrinks back into.
    func zoomSource(_ id: String, in namespace: Namespace.ID, cornerRadius: CGFloat) -> some View {
        matchedTransitionSource(id: id, in: namespace) { source in
            source.clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

/// The scene's page: its picture zooms up out of the tapped thumbnail and settles across the
/// top, with the story, facts, and cast below and the choice to dub it pinned at the bottom.
/// Swiping down shrinks it back into the thumbnail.
struct SceneDetailView: View {
    let scene: SceneClip
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var clip = LoopingClip()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(scene.title)
                            .dubFont(32, weight: .bold)
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(scene.source.title) · \(String(scene.source.year)) · \(scene.source.format)")
                            .dubFont(15, weight: .medium)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Text(scene.synopsis)
                        .dubFont(17, weight: .regular)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    SceneFacts(scene: scene)
                    SceneCast(scene: scene)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .ignoresSafeArea(edges: .top)
        .scrollIndicators(.hidden)
        .screenBackground()
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Button("Not now") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 140)
                Button("Dub this scene") {
                    model.startDub(scene: scene, lockedCharacterID: nil, partner: nil)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Palette.background)
        }
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !reduceMotion else { return }
            clip.loadPicture(of: scene, seconds: ScenePreviewSheet.previewSeconds)
            clip.player.play()
        }
        .onDisappear { clip.player.pause() }
    }

    /// The thumbnail grown up: artwork with the silent clip over it, fading into the page.
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkView(artwork: scene.artwork)
            if !reduceMotion {
                PlayerSurface(player: clip.player, gravity: .resizeAspectFill)
            }
            LinearGradient(colors: [.clear, Palette.background], startPoint: .center, endPoint: .bottom)
        }
        .aspectRatio(4 / 5, contentMode: .fit)
        .clipped()
        .accessibilityHidden(true)
    }
}
