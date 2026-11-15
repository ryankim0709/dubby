import AVFoundation
import SwiftUI

struct DiscoverView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var language: String?
    @State private var openings: [SceneOpening] = []
    @Namespace private var zoomNamespace

    /// Thumbnails open their scene by pushing a detail page that zooms out of them.
    private var zoom: SceneZoom {
        SceneZoom(namespace: zoomNamespace) { opening in openings.append(opening) }
    }

    private var languages: [String] {
        var seen = Set<String>()
        return model.scenes.map(\.language).filter { seen.insert($0).inserted }
    }

    private var inLanguage: [SceneClip] {
        model.scenes.filter { language == nil || $0.language == language }
    }

    /// The scene of the day sits in the middle of the deck so other scenes fan out on both sides.
    private var deckScenes: [SceneClip] {
        let others = inLanguage.filter { $0.id != SampleData.featured.id }
        let featured = inLanguage.filter { $0.id == SampleData.featured.id }
        let middle = others.count / 2
        return Array(others[..<middle]) + featured + Array(others[middle...])
    }

    /// The deck opens on the scene of the day when it's in the list, otherwise on the middle card.
    private var deckStartIndex: Int {
        deckScenes.firstIndex { $0.id == SampleData.featured.id } ?? deckScenes.count / 2
    }

    private var results: [SceneClip] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return inLanguage.filter { scene in
            scene.title.localizedCaseInsensitiveContains(trimmed)
                || scene.source.title.localizedCaseInsensitiveContains(trimmed)
                || scene.characters.contains { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    var body: some View {
        NavigationStack(path: $openings) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    languageTabs
                    if !query.isEmpty {
                        searchResults
                    } else {
                        SceneDeck(scenes: deckScenes, startIndex: deckStartIndex, zoom: zoom)
                        MostDubbedList(scenes: inLanguage.sorted { $0.dubCount > $1.dubCount }, zoom: zoom)
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .screenBackground()
            .searchable(text: $query, prompt: "Scenes, films, characters")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SceneOpening.self) { opening in
                SceneDetailView(scene: opening.scene)
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
                // The wordmark is a logo, not a button, so it sits on the bar without a glass capsule.
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    Label("\(SampleData.streakDays)", systemImage: "flame.fill")
                        .labelStyle(.titleAndIcon)
                        .dubFont(15, weight: .semibold)
                        .foregroundStyle(Palette.textPrimary)
                        .accessibilityLabel("\(SampleData.streakDays)-day streak")
                }
            }
        }
    }

    /// Text tabs: the selected language in white, the rest in grey.
    private var languageTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 22) {
                tab(title: "All", isSelected: language == nil) { language = nil }
                ForEach(languages, id: \.self) { item in
                    tab(title: item, isSelected: language == item) { language = item }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .padding(.top, 4)
    }

    private func tab(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .dubFont(17, weight: isSelected ? .semibold : .medium)
                .foregroundStyle(isSelected ? Palette.textPrimary : Palette.placeholder)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var searchResults: some View {
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 22) {
                ForEach(results) { scene in
                    PosterCard(scene: scene, sourceID: "search-\(scene.id)", zoom: zoom)
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

/// A stacked deck of posters like a fanned hand: the focused one in front, neighbours tucked
/// behind it smaller and dimmer. Swipe sideways to deal through it; the focused scene's film
/// sits centred underneath.
private struct SceneDeck: View {
    let scenes: [SceneClip]
    let startIndex: Int
    let zoom: SceneZoom
    @State private var focusedIndex: Int
    @State private var dragOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let cardWidth: CGFloat = 220

    init(scenes: [SceneClip], startIndex: Int, zoom: SceneZoom) {
        self.scenes = scenes
        self.startIndex = startIndex
        self.zoom = zoom
        _focusedIndex = State(initialValue: startIndex)
    }
    /// Drag distance that moves the deck by one card.
    private var step: CGFloat { cardWidth * 0.6 }

    private var focused: SceneClip? {
        scenes.indices.contains(focusedIndex) ? scenes[focusedIndex] : scenes.first
    }

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                ForEach(Array(scenes.enumerated()), id: \.element.id) { index, scene in
                    let position = Double(index - focusedIndex) + Double(dragOffset / step)
                    let depth = min(abs(position), 2.5)
                    CarouselPoster(scene: scene, isFocused: index == focusedIndex && dragOffset == 0, zoom: zoom) {
                        withAnimation(.spring(duration: 0.4, bounce: 0.15)) { focusedIndex = index }
                    }
                    .frame(width: cardWidth)
                    .overlay {
                        // Cards further back sit in shadow.
                        RoundedRectangle(cornerRadius: Radius.poster)
                            .fill(.black.opacity(0.28 * depth))
                            .allowsHitTesting(false)
                    }
                    .scaleEffect(1 - 0.13 * depth)
                    .offset(x: horizontalOffset(for: position))
                    .zIndex(-depth)
                    .opacity(depth > 2.2 ? 0 : 1)
                    .accessibilityHidden(index != focusedIndex)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: cardWidth * 1.5)
            .contentShape(Rectangle())
            .simultaneousGesture(deal)
            .accessibilityElement(children: .contain)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: move(by: 1)
                case .decrement: move(by: -1)
                @unknown default: break
                }
            }

            if let focused {
                // The poster already carries the clip's name; underneath goes where it's from.
                VStack(spacing: 4) {
                    Text(focused.source.title)
                        .dubFont(22, weight: .bold)
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text("\(String(focused.source.year)) · \(focused.language)")
                        .dubFont(15, weight: .medium)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity)
                .id(focused.id)
                .transition(.opacity)
                .accessibilityElement(children: .combine)

                HStack(spacing: 6) {
                    ForEach(scenes.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == focusedIndex ? Palette.textPrimary : Palette.track)
                            .frame(width: index == focusedIndex ? 16 : 6, height: 6)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: focusedIndex)
        .onChange(of: scenes.map(\.id)) {
            focusedIndex = startIndex
            dragOffset = 0
        }
    }

    /// Neighbours tuck in close; cards further back fan out only a little more.
    private func horizontalOffset(for position: Double) -> CGFloat {
        let distance = abs(position)
        let near = min(distance, 1) * 0.42
        let far = max(0, min(distance, 2) - 1) * 0.22
        return CGFloat(position.sign == .minus ? -1 : 1) * cardWidth * CGFloat(near + far)
    }

    /// Horizontal drags deal through the deck; vertical ones are left to the page's scroll view.
    private var deal: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let predicted = -value.predictedEndTranslation.width / step
                let target = min(max(Int((Double(focusedIndex) + predicted).rounded()), 0), scenes.count - 1)
                withAnimation(.spring(duration: 0.45, bounce: 0.18)) {
                    focusedIndex = abs(value.translation.width) > abs(value.translation.height) ? target : focusedIndex
                    dragOffset = 0
                }
            }
    }

    private func move(by delta: Int) {
        focusedIndex = min(max(focusedIndex + delta, 0), scenes.count - 1)
    }
}

private struct CarouselPoster: View {
    let scene: SceneClip
    let isFocused: Bool
    let zoom: SceneZoom
    let onBringForward: () -> Void
    @State private var clip = LoopingClip()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sourceID: String { "deck-\(scene.id)" }

    var body: some View {
        Button {
            if isFocused {
                zoom.open(SceneOpening(scene: scene, sourceID: sourceID))
            } else {
                onBringForward()
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                ArtworkView(artwork: scene.artwork)
                if isFocused && !reduceMotion {
                    PlayerSurface(player: clip.player, gravity: .resizeAspectFill)
                        .transition(.opacity)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                Text(scene.title.uppercased())
                    .displayFont(30)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                    .padding(14)
            }
            .aspectRatio(2 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Radius.poster))
            .zoomSource(sourceID, in: zoom.namespace, cornerRadius: Radius.poster)
            .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(scene.title), from \(scene.source.title)")
        .accessibilityHint(isFocused ? "Opens a preview" : "Brings this scene to the front")
        .onChange(of: isFocused, initial: true) { _, focused in
            guard focused, !reduceMotion else {
                clip.player.pause()
                return
            }
            if clip.player.currentItem == nil {
                clip.loadPicture(of: scene, seconds: scene.duration)
            }
            clip.player.play()
        }
        .onDisappear { clip.player.pause() }
    }
}

/// A one-sheet: artwork with the title printed in the poster face, then source and dub count below.
struct PosterCard: View {
    let scene: SceneClip
    let sourceID: String
    let zoom: SceneZoom

    var body: some View {
        Button {
            zoom.open(SceneOpening(scene: scene, sourceID: sourceID))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ArtworkView(artwork: scene.artwork)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        Text(scene.title.uppercased())
                            .displayFont(26)
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(3)
                            .minimumScaleFactor(0.8)
                            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                            .padding(12)
                    }
                    .overlay(alignment: .topLeading) {
                        Text(scene.language)
                            .dubFont(11, weight: .bold)
                            .foregroundStyle(Palette.textPrimary)
                            .padding(.horizontal, 8)
                            .frame(minHeight: 22)
                            .background(.black.opacity(0.45), in: Capsule())
                            .padding(10)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                    .zoomSource(sourceID, in: zoom.namespace, cornerRadius: Radius.card)
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.source.title)
                        .dubFont(15, weight: .semibold)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Text("\(scene.dubCount.compactCount) dubs")
                        .dubFont(13, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens a preview")
    }
}

/// The most dubbed scenes overall as a ranked list; the rank is the point, so it's set large.
private struct MostDubbedList: View {
    let scenes: [SceneClip]
    let zoom: SceneZoom

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Most dubbed")
                .dubFont(24, weight: .bold)
                .foregroundStyle(Palette.textPrimary)
            VStack(spacing: 0) {
                ForEach(Array(scenes.prefix(5).enumerated()), id: \.element.id) { index, scene in
                    Button {
                        zoom.open(SceneOpening(scene: scene, sourceID: "rank-\(scene.id)"))
                    } label: {
                        HStack(spacing: 16) {
                            Text("\(index + 1)")
                                .dubFont(34, weight: .heavy)
                                .foregroundStyle(index == 0 ? Palette.textPrimary : Palette.placeholder)
                                .monospacedDigit()
                                .frame(width: 30, alignment: .leading)
                            ArtworkView(artwork: scene.artwork)
                                .frame(width: 52, height: 70)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .zoomSource("rank-\(scene.id)", in: zoom.namespace, cornerRadius: 10)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(scene.title)
                                    .dubFont(17, weight: .semibold)
                                    .foregroundStyle(Palette.textPrimary)
                                    .lineLimit(1)
                                Text("\(scene.source.title) · \(scene.language)")
                                    .dubFont(14, weight: .regular)
                                    .foregroundStyle(Palette.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(scene.dubCount.compactCount)
                                .dubFont(14, weight: .semibold)
                                .foregroundStyle(Palette.textSecondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Number \(index + 1): \(scene.title), \(scene.source.title), \(scene.dubCount) dubs")
                    .overlay(alignment: .bottom) {
                        if index < min(scenes.count, 5) - 1 {
                            Rectangle().fill(Palette.hairline).frame(height: 1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }
}
