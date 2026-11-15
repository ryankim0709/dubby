import SwiftUI

/// Something loaded from disk or the bundle, with its failure shown rather than hidden.
enum LoadState<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}

/// Shows loading and failure states, and the content once loaded.
struct LoadStateContent<Value, Content: View>: View {
    let state: LoadState<Value>
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .loading:
            ProgressView()
                .tint(Palette.accentText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        case .failed(let message):
            EmptyStateView(systemImage: "exclamationmark.triangle", title: "Couldn't load this", message: message)
        case .loaded(let value):
            content(value)
        }
    }
}

struct DiscoverView: View {
    let clips: LoadState<[LibraryClip]>
    let streakDays: Int
    let onDub: (LibraryClip) -> Void
    let onTalkToCoach: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("dub.it")
                        .dubFont(24, weight: .semibold)
                        .italic()
                        .foregroundStyle(Palette.accentText)
                    Spacer()
                    if streakDays > 0 {
                        Text("🔥 \(streakDays)")
                            .dubFont(16, weight: .regular)
                            .foregroundStyle(Palette.streak)
                            .accessibilityLabel("\(streakDays)-day streak")
                    }
                }
                .padding(.top, 8)
                Button(action: onTalkToCoach) {
                    Label("Talk to a coach", systemImage: "person.wave.2")
                }
                .buttonStyle(OutlineCapsuleButtonStyle())
                .accessibilityIdentifier("talkToCoach")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scenes")
                        .dubFont(18, weight: .semibold)
                        .foregroundStyle(Palette.textPrimary)
                    Text("Pick a scene, choose who you'll play, and dub their lines.")
                        .dubFont(14, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                }
                LoadStateContent(state: clips) { clips in
                    if clips.isEmpty {
                        EmptyStateView(
                            systemImage: "film.stack",
                            title: "No scenes yet",
                            message: "Add MP4 or MOV clips to the Media folder in the project, then build and run again."
                        )
                    } else {
                        VStack(spacing: 16) {
                            ForEach(clips) { clip in
                                SceneCard(clip: clip) { onDub(clip) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .background(Palette.background)
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// A clip with its thumbnail, length, and a button to start dubbing it.
struct SceneCard: View {
    let clip: LibraryClip
    let onDub: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VideoThumbnail(url: clip.url)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    Text(clip.durationSeconds.preciseClockString)
                        .dubFont(12, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 22)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(8)
                }
            VStack(alignment: .leading, spacing: 12) {
                Text(clip.title)
                    .dubFont(18, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
                Button("Dub this scene", action: onDub)
                    .buttonStyle(PrimaryButtonStyle(cornerRadius: 12))
                    .accessibilityIdentifier("dubScene")
            }
            .padding(12)
            .background(Palette.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
