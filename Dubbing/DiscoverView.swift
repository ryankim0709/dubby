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
    let retry: (() -> Void)?
    let failureIdentifier: String?
    @ViewBuilder let content: (Value) -> Content

    init(state: LoadState<Value>, @ViewBuilder content: @escaping (Value) -> Content) {
        self.state = state
        retry = nil
        failureIdentifier = nil
        self.content = content
    }

    init(state: LoadState<Value>, failureIdentifier: String, retry: @escaping () -> Void, @ViewBuilder content: @escaping (Value) -> Content) {
        self.state = state
        self.retry = retry
        self.failureIdentifier = failureIdentifier
        self.content = content
    }

    var body: some View {
        switch state {
        case .loading:
            ProgressView()
                .tint(Palette.accentText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .accessibilityLabel("Loading")
        case .failed(let message):
            VStack(spacing: 12) {
                EmptyStateView(systemImage: "exclamationmark.triangle", title: "Couldn't load this", message: message)
                    .accessibilityIdentifier(failureIdentifier ?? "loadFailed")
                if let retry {
                    Button("Try again", action: retry)
                        .buttonStyle(.dubSecondary)
                        .accessibilityIdentifier("retryLoad")
                }
            }
        case .loaded(let value):
            content(value)
        }
    }
}

struct DiscoverView: View {
    let clips: LoadState<[LibraryClip]>
    let streakDays: Int
    let onDub: (LibraryClip) -> Void
    let isSignedIn: Bool
    let onTalkToCoach: () -> Void
    let onAccount: () -> Void
    let onRetry: () -> Void

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
                    DubGlassIconButton(
                        systemImage: isSignedIn ? "person.crop.circle.fill" : "person.crop.circle",
                        label: isSignedIn ? "Account, signed in" : "Account, signed out",
                        action: onAccount
                    )
                    .accessibilityIdentifier("openAccount")
                }
                .padding(.top, 8)
                Button(action: onTalkToCoach) {
                    Label("Talk to a coach", systemImage: "person.wave.2")
                }
                .buttonStyle(.dubSecondary)
                .accessibilityIdentifier("talkToCoach")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scenes")
                        .dubFont(18, weight: .semibold)
                        .foregroundStyle(Palette.textPrimary)
                    Text("Pick a scene, choose who you'll play, and dub their lines.")
                        .dubFont(14, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                }
                LoadStateContent(state: clips, failureIdentifier: "discoverLoadFailed", retry: onRetry) { clips in
                    if clips.isEmpty {
                        EmptyStateView(
                            systemImage: "film.stack",
                            title: "No scenes in this build",
                            message: "Scenes are the MP4 or MOV clips bundled from the Media folder. Add one there, then build and run again."
                        )
                        .accessibilityIdentifier("discoverEmpty")
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
            .containerIdentifier("discoverScreen")
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
                        .dubGlass(in: Capsule())
                        .padding(8)
                }
            VStack(alignment: .leading, spacing: 12) {
                Text(clip.title)
                    .dubFont(18, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
                Button("Dub this scene", action: onDub)
                    .buttonStyle(.dubPrimary)
                    .accessibilityIdentifier("dubScene-\(clip.sceneID)")
            }
            .padding(12)
            .background(Palette.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .containerIdentifier("sceneCard-\(clip.sceneID)")
    }
}
