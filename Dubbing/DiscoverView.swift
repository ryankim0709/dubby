import AVKit
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
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("retryLoad")
                }
            }
        case .loaded(let value):
            content(value)
        }
    }
}

private struct LibrarySceneOpening: Hashable {
    let clip: LibraryClip
    let sourceID: String
}

struct DiscoverView: View {
    let clips: LoadState<[LibraryClip]>
    let streakDays: Int
    let onDub: (LibraryClip) -> Void
    let isSignedIn: Bool
    let onTalkToCoach: () -> Void
    let onAccount: () -> Void
    let onRetry: () -> Void
    @State private var query = ""
    @State private var openings: [LibrarySceneOpening] = []
    @Namespace private var zoomNamespace

    var body: some View {
        NavigationStack(path: $openings) {
            ScrollView {
                LoadStateContent(state: clips, failureIdentifier: "discoverLoadFailed", retry: onRetry) { clips in
                    library(clips)
                }
                .padding(.bottom, 24)
                .containerIdentifier("discoverScreen")
            }
            .scrollIndicators(.hidden)
            .screenBackground()
            .searchable(text: $query, prompt: "Search your scenes")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: LibrarySceneOpening.self) { opening in
                LibrarySceneDetail(clip: opening.clip, onDub: { onDub(opening.clip) }, onClose: { openings = [] })
                    .navigationTransition(.zoom(sourceID: opening.sourceID, in: zoomNamespace))
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("DUB\(Text("BY").foregroundStyle(Palette.textSecondary))")
                        .displayFont(30)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize()
                        .accessibilityLabel("Dubby")
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    if streakDays > 0 {
                        Label("\(streakDays)", systemImage: "flame.fill")
                            .dubFont(15, weight: .semibold)
                            .accessibilityLabel("\(streakDays)-day streak")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onAccount) {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel(isSignedIn ? "Account, signed in" : "Account, signed out")
                    .accessibilityIdentifier("openAccount")
                }
            }
        }
    }

    @ViewBuilder
    private func library(_ clips: [LibraryClip]) -> some View {
        let results = clips.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        if clips.isEmpty {
            EmptyStateView(systemImage: "film.stack", title: "Your next role is waiting", message: "Library scenes appear here when they are available. Try loading the library again.")
                .accessibilityIdentifier("discoverEmpty")
        } else if !query.isEmpty {
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                VStack(spacing: 16) {
                    ForEach(results) { clip in
                        SceneCard(clip: clip) { open(clip, from: "search") }
                            .matchedTransitionSource(id: "search-\(clip.sceneID)", in: zoomNamespace)
                    }
                }
                .padding(.horizontal, 20)
            }
        } else {
            VStack(alignment: .leading, spacing: 32) {
                HStack {
                    Text("All scenes")
                        .dubFont(17, weight: .semibold)
                    Spacer()
                    Text("\(clips.count) available")
                        .dubFont(15, weight: .medium)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                LibraryPosterDeck(clips: clips, namespace: zoomNamespace) { clip in
                    open(clip, from: "deck")
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("Ready for your voice")
                        .dubFont(24, weight: .bold)
                    ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                        Button { open(clip, from: "library") } label: {
                            HStack(spacing: 14) {
                                Text("\(index + 1)")
                                    .dubFont(34, weight: .heavy)
                                    .foregroundStyle(index == 0 ? Palette.textPrimary : Palette.placeholder)
                                    .frame(width: 28)
                                VideoThumbnail(url: clip.url)
                                    .frame(width: 52, height: 70)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .matchedTransitionSource(id: "library-\(clip.sceneID)", in: zoomNamespace)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(clip.title)
                                        .dubFont(16, weight: .semibold)
                                        .foregroundStyle(Palette.textPrimary)
                                        .multilineTextAlignment(.leading)
                                    Text("\(clip.durationSeconds.preciseClockString) · Choose your moment")
                                        .dubFont(14, weight: .regular)
                                        .foregroundStyle(Palette.textSecondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            .frame(minHeight: 80)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("libraryScene-\(clip.sceneID)")
                        if index < clips.count - 1 { Divider().overlay(Palette.divider) }
                    }
                }
                .padding(.horizontal, 20)
                Button(action: onTalkToCoach) {
                    HStack(spacing: 14) {
                        Image(systemName: "person.wave.2")
                            .dubFont(26, weight: .regular)
                            .foregroundStyle(Palette.holo)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("A character in your corner")
                                .dubFont(17, weight: .semibold)
                                .foregroundStyle(Palette.textPrimary)
                            Text("Talk through your next scene with a coach.")
                                .dubFont(14, weight: .regular)
                                .foregroundStyle(Palette.textSecondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .padding(18)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("talkToCoach")
                .padding(.horizontal, 20)
            }
            .foregroundStyle(Palette.textPrimary)
        }
    }

    private func open(_ clip: LibraryClip, from section: String) {
        openings.append(LibrarySceneOpening(clip: clip, sourceID: "\(section)-\(clip.sceneID)"))
    }
}

struct ScenePoster: View {
    let clip: LibraryClip

    var body: some View {
        VideoThumbnail(url: clip.url)
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .topLeading) {
                MetaPill(text: clip.durationSeconds.preciseClockString, systemImage: "film")
                    .padding(14)
            }
            .overlay(alignment: .bottomLeading) {
                Text(clip.title.uppercased().replacingOccurrences(of: "-", with: "‑"))
                    .displayFont(36)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .minimumScaleFactor(0.6)
                    .padding(20)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.poster))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(clip.title), \(clip.durationSeconds.preciseClockString)")
    }
}

private struct LibraryPosterDeck: View {
    let clips: [LibraryClip]
    let namespace: Namespace.ID
    let onOpen: (LibraryClip) -> Void
    @State private var focusedIndex = 0
    @State private var dragOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let cardWidth: CGFloat = 220
    private var step: CGFloat { cardWidth * 0.6 }

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                    let position = Double(index - focusedIndex) + Double(dragOffset / step)
                    let depth = min(abs(position), 2.5)
                    Button {
                        if index == focusedIndex { onOpen(clip) }
                        else { focus(index) }
                    } label: {
                        ScenePoster(clip: clip)
                            .matchedTransitionSource(id: "deck-\(clip.sceneID)", in: namespace)
                    }
                    .buttonStyle(.plain)
                    .frame(width: cardWidth)
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.poster)
                            .fill(.black.opacity(0.28 * depth))
                            .allowsHitTesting(false)
                    }
                    .scaleEffect(1 - 0.13 * depth)
                    .offset(x: horizontalOffset(for: position))
                    .zIndex(-depth)
                    .opacity(depth > 2.2 ? 0 : 1)
                    .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 14)
                    .accessibilityHidden(index != focusedIndex)
                    .accessibilityIdentifier("scenePoster-\(clip.sceneID)")
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: cardWidth * 1.5)
            .contentShape(Rectangle())
            .simultaneousGesture(deal)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: focus(min(focusedIndex + 1, clips.count - 1))
                case .decrement: focus(max(focusedIndex - 1, 0))
                @unknown default: break
                }
            }
            if clips.indices.contains(focusedIndex) {
                VStack(spacing: 5) {
                    Text(clips[focusedIndex].title)
                        .dubFont(22, weight: .bold)
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.center)
                    Text("Pick a scene. Make it yours.")
                        .dubFont(15, weight: .medium)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.horizontal, 32)
            }
            if clips.count > 1 {
                HStack(spacing: 6) {
                    ForEach(clips.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == focusedIndex ? Palette.textPrimary : Palette.track)
                            .frame(width: index == focusedIndex ? 16 : 6, height: 6)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .onChange(of: clips.map(\.id)) { focusedIndex = 0 }
    }

    private func horizontalOffset(for position: Double) -> CGFloat {
        let distance = abs(position)
        let offset = min(distance, 1) * 0.42 + max(0, min(distance, 2) - 1) * 0.22
        return (position < 0 ? -1 : 1) * cardWidth * offset
    }

    private func focus(_ index: Int) {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.15)) {
            focusedIndex = index
            dragOffset = 0
        }
    }

    private var deal: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = reduceMotion ? 0 : value.translation.width
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let predicted = -value.predictedEndTranslation.width / step
                focus(min(max(Int((Double(focusedIndex) + predicted).rounded()), 0), clips.count - 1))
            }
    }
}

/// A compact poster row used by the create flow and search results.
struct SceneCard: View {
    let clip: LibraryClip
    let onDub: () -> Void

    var body: some View {
        Button(action: onDub) {
            HStack(spacing: 16) {
                VideoThumbnail(url: clip.url)
                    .frame(width: 76, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 8) {
                    Text(clip.title)
                        .dubFont(18, weight: .semibold)
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(clip.durationSeconds.preciseClockString)
                        .dubFont(14, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                    Text("Dub this scene")
                        .dubFont(14, weight: .semibold)
                        .foregroundStyle(Palette.textPrimary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(14)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dubScene-\(clip.sceneID)")
        .containerIdentifier("sceneCard-\(clip.sceneID)")
    }
}
