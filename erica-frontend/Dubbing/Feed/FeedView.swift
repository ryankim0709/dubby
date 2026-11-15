import AVFoundation
import SwiftUI

/// Full-screen dubs, one per page. Only the visible page plays.
struct FeedView: View {
    @Environment(AppModel.self) private var model
    @State private var visibleID: String?
    /// Tabs stay alive in the background, so the feed tracks whether it's actually showing.
    @State private var isOnScreen = false

    private var canPlay: Bool {
        isOnScreen && model.previewScene == nil && model.activeDub == nil
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(model.feed) { post in
                    FeedPage(post: post, isActive: canPlay && (visibleID ?? model.feed.first?.id) == post.id)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(post.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $visibleID)
        .scrollIndicators(.hidden)
        .background(.black)
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
    }
}

private struct FeedPage: View {
    let post: FeedPost
    let isActive: Bool
    @Environment(AppModel.self) private var model
    @State private var clip = LoopingClip()
    @State private var hasReacted = false

    var body: some View {
        ZStack {
            Color.black
            PlayerSurface(player: clip.player, gravity: .resizeAspect)
                .aspectRatio(16 / 9, contentMode: .fit)
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            HStack(alignment: .bottom, spacing: 16) {
                credits
                Spacer(minLength: 0)
                reactionRail
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .task(id: isActive) {
            if isActive {
                if clip.player.currentItem == nil {
                    clip.loadPicture(of: post.scene, seconds: post.scene.duration)
                }
                clip.player.play()
            } else {
                clip.player.pause()
            }
        }
    }

    private var credits: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AvatarStack(friends: post.credits.map(\.author), size: 34)
                Text(post.credits.map { "@\($0.author.handle)" }.joined(separator: " × "))
                    .dubFont(15, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
            }
            Text(roleLine)
                .dubFont(14, weight: .medium)
                .foregroundStyle(Palette.textSecondary)
            Text(post.caption)
                .dubFont(15, weight: .regular)
                .foregroundStyle(Palette.textPrimary)
            Text("\(post.scene.source.title) · \(post.postedText)")
                .dubFont(13, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
            Button {
                model.preview(post.scene)
            } label: {
                Label("Dub this scene", systemImage: "mic.fill")
                    .dubFont(14, weight: .bold)
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .background(Palette.accent, in: Capsule())
            }
            .padding(.top, 4)
        }
        .accessibilityElement(children: .contain)
    }

    private var roleLine: String {
        post.credits
            .map { credit in "\(credit.author.name) as \(post.scene.character(id: credit.characterID)?.name ?? "")" }
            .joined(separator: " · ")
    }

    private var reactionRail: some View {
        VStack(spacing: 20) {
            railButton(
                systemImage: "flame.fill",
                count: post.reactions + (hasReacted ? 1 : 0),
                tint: hasReacted ? Palette.record : Palette.textPrimary,
                label: hasReacted ? "Remove reaction" : "React"
            ) {
                hasReacted.toggle()
            }
            .sensoryFeedback(.impact(weight: .light), trigger: hasReacted)
            railButton(systemImage: "bubble.right.fill", count: post.comments, tint: Palette.textPrimary, label: "Comments") {}
            railButton(systemImage: "arrowshape.turn.up.right.fill", count: nil, tint: Palette.textPrimary, label: "Share") {}
        }
    }

    private func railButton(systemImage: String, count: Int?, tint: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                if let count {
                    Text(count.compactCount)
                        .dubFont(12, weight: .semibold)
                        .foregroundStyle(Palette.textPrimary)
                        .monospacedDigit()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(count.map { "\($0)" } ?? "")
    }
}
