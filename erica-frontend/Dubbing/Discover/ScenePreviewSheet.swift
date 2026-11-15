import AVFoundation
import SwiftUI

/// A silent ten-second look at the scene, where it comes from, and what happens, then
/// a clear choice: dub it or keep browsing.
struct ScenePreviewSheet: View {
    static let previewSeconds = 10.0

    let scene: SceneClip
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var clip = LoopingClip()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    player
                    VStack(alignment: .leading, spacing: 8) {
                        Text(scene.title)
                            .dubFont(30, weight: .bold)
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
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
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
        }
        .screenBackground()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.background)
        .onAppear {
            clip.loadPicture(of: scene, seconds: Self.previewSeconds)
            clip.player.play()
        }
        .onDisappear { clip.player.pause() }
    }

    private var player: some View {
        PlayerSurface(player: clip.player, gravity: .resizeAspectFill)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(alignment: .bottom) {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    let elapsed = clip.player.currentTime().seconds
                    let fraction = elapsed.isFinite ? min(1, max(0, elapsed / Self.previewSeconds)) : 0
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(Palette.accent)
                            .frame(width: proxy.size.width * fraction, height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .accessibilityHidden(true)
            }
            .overlay {
                if clip.loadError != nil {
                    Text("Preview unavailable")
                        .dubFont(14, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .padding(.top, 20)
    }
}

/// Language, length, line count, and level in one row.
struct SceneFacts: View {
    let scene: SceneClip

    var body: some View {
        HStack(spacing: 0) {
            fact(value: scene.language, label: "Language")
            fact(value: "\(Int(scene.duration))s", label: "Length")
            fact(value: "\(scene.lines.count)", label: "Lines")
            fact(value: scene.difficulty.rawValue, label: "Level")
        }
        .padding(.vertical, 14)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card))
    }

    private func fact(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .dubFont(16, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The scene's characters with how much each one says.
struct SceneCast: View {
    let scene: SceneClip

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast")
                .dubFont(17, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
            ForEach(scene.characters) { character in
                HStack(spacing: 12) {
                    ArtworkView(artwork: character.artwork)
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(character.name)
                            .dubFont(16, weight: .semibold)
                            .foregroundStyle(Palette.textPrimary)
                        Text(character.tagline)
                            .dubFont(14, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    Text("\(scene.lines(for: character.id).count) lines")
                        .dubFont(14, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
