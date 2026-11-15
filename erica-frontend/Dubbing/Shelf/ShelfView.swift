import AVKit
import SwiftUI

/// The profile as a collection: every dub stands on the shelf like a DVD case.
struct ShelfView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: ShelfFilter = .all
    @State private var selectedDubID: String?
    @State private var isShowingSettings = false
    /// Set when the detail sheet asks to re-dub; the preview opens once that sheet is gone.
    @State private var sceneToRedub: SceneClip?

    private enum ShelfFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case coDubs = "Co-dubs"
        case drafts = "Drafts"

        var id: Self { self }
    }

    private var filtered: [ShelfDub] {
        model.shelf.filter { dub in
            switch filter {
            case .all: true
            case .coDubs: dub.collaborator != nil
            case .drafts: if case .draft = dub.progress { true } else { false }
            }
        }
    }

    private var finishedScores: [Int] {
        model.shelf.compactMap { dub -> Int? in
            if case .finished(let score) = dub.progress { return score }
            return nil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    profileHeader
                    Picker("Show", selection: $filter) {
                        ForEach(ShelfFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    if filtered.isEmpty {
                        ContentUnavailableView("Nothing on this shelf yet", systemImage: "film.stack", description: Text("Finished dubs land here."))
                    } else {
                        shelves
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .screenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsSheet()
            }
            .sheet(item: selectedDubBinding, onDismiss: openQueuedRedub) { dub in
                ShelfDubDetail(dubID: dub.id) { scene in
                    sceneToRedub = scene
                    selectedDubID = nil
                }
            }
        }
    }

    private func openQueuedRedub() {
        guard let sceneToRedub else { return }
        self.sceneToRedub = nil
        model.preview(sceneToRedub)
    }

    private var selectedDubBinding: Binding<ShelfDub?> {
        Binding(
            get: { model.shelf.first { $0.id == selectedDubID } },
            set: { selectedDubID = $0?.id }
        )
    }

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                AvatarView(friend: model.me, size: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.me.name)
                        .dubFont(30, weight: .bold)
                        .foregroundStyle(Palette.textPrimary)
                    Text("@\(model.me.handle)")
                        .dubFont(15, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            HStack(spacing: 24) {
                stat(value: "\(finishedScores.count)", label: "dubs")
                stat(value: "\(SampleData.streakDays)", label: "day streak")
                if !finishedScores.isEmpty {
                    stat(value: "\(finishedScores.reduce(0, +) / finishedScores.count)", label: "avg timing")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func stat(value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                .dubFont(22, weight: .bold)
                .foregroundStyle(Palette.textPrimary)
                .monospacedDigit()
            Text(label)
                .dubFont(14, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var shelves: some View {
        let perShelf = 3
        let rows = stride(from: 0, to: filtered.count, by: perShelf).map { Array(filtered[$0..<min($0 + perShelf, filtered.count)]) }
        return VStack(spacing: 28) {
            ForEach(rows, id: \.first?.id) { row in
                VStack(spacing: 0) {
                    HStack(alignment: .bottom, spacing: 14) {
                        ForEach(row) { dub in
                            Button {
                                selectedDubID = dub.id
                            } label: {
                                DVDCase(dub: dub)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(row.count..<perShelf, id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 22)
                    ShelfPlank()
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct DVDCase: View {
    let dub: ShelfDub

    private var characterName: String { dub.scene.character(id: dub.characterID)?.name ?? "" }

    var body: some View {
        ArtworkView(artwork: dub.scene.artwork)
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(dub.scene.title.uppercased())
                        .displayFont(20)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                    Text("as \(characterName)")
                        .dubFont(11, weight: .semibold)
                        .foregroundStyle(Palette.textPrimary.opacity(0.85))
                }
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .padding(.leading, 12)
                .padding([.trailing, .bottom], 7)
            }
            // The case's hinge: a darker spine with a sliver of light on its edge.
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    Rectangle().fill(.black.opacity(0.4)).frame(width: 5)
                    Rectangle().fill(.white.opacity(0.18)).frame(width: 1)
                }
            }
            .overlay(alignment: .topTrailing) {
                badge
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var badge: some View {
        if case .draft = dub.progress {
            Text("DRAFT")
                .dubFont(10, weight: .bold)
                .foregroundStyle(Palette.onAccent)
                .padding(.horizontal, 6)
                .frame(minHeight: 18)
                .background(Palette.accent, in: Capsule())
        } else if let collaborator = dub.collaborator {
            AvatarView(friend: collaborator, size: 22)
                .overlay(Circle().stroke(Palette.background, lineWidth: 1.5))
        } else if dub.visibility == .privateShelf {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 22, height: 22)
                .background(.black.opacity(0.5), in: Circle())
        }
    }

    private var accessibilityText: String {
        var parts = ["\(dub.scene.title), as \(characterName)"]
        if let collaborator = dub.collaborator { parts.append("with \(collaborator.name)") }
        if case .draft = dub.progress { parts.append("draft") }
        parts.append(dub.visibility == .publicFeed ? "public" : "private")
        return parts.joined(separator: ", ")
    }
}

private struct ShelfPlank: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Palette.accent.opacity(0.25))
                .frame(height: 1)
            Rectangle()
                .fill(LinearGradient(colors: [Palette.shelfWood, Palette.shelfWoodShadow], startPoint: .top, endPoint: .bottom))
                .frame(height: 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .shadow(color: .black.opacity(0.7), radius: 8, x: 0, y: 8)
        .accessibilityHidden(true)
    }
}

private struct ShelfDubDetail: View {
    let dubID: String
    let onRedub: (SceneClip) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var clip = LoopingClip()

    private var dub: ShelfDub? { model.shelf.first { $0.id == dubID } }

    var body: some View {
        NavigationStack {
            if let dub {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Group {
                            if dub.videoURL != nil {
                                VideoPlayer(player: player)
                            } else {
                                PlayerSurface(player: clip.player, gravity: .resizeAspectFill)
                            }
                        }
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(dub.scene.title)
                                .dubFont(28, weight: .bold)
                                .foregroundStyle(Palette.textPrimary)
                            Text(subtitle(for: dub))
                                .dubFont(15, weight: .regular)
                                .foregroundStyle(Palette.textSecondary)
                        }
                        Toggle(isOn: visibilityBinding(for: dub)) {
                            Text("Show on the public feed")
                                .dubFont(16, weight: .semibold)
                                .foregroundStyle(Palette.textPrimary)
                        }
                        .tint(Palette.toggleOn)
                        .padding(14)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card))
                        if let url = dub.videoURL {
                            ShareLink(item: url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }
                        Button("Dub this scene again") {
                            onRedub(dub.scene)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(16)
                }
                .screenBackground()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .task {
                    if let url = dub.videoURL {
                        player.replaceCurrentItem(with: AVPlayerItem(url: url))
                        // Browsing stays silent; the dub's sound plays in Photos or wherever it's shared.
                        player.isMuted = true
                        player.play()
                    } else {
                        clip.loadPicture(of: dub.scene, seconds: dub.scene.duration)
                        clip.player.play()
                    }
                }
                .onDisappear {
                    player.pause()
                    clip.player.pause()
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Palette.background)
    }

    private func subtitle(for dub: ShelfDub) -> String {
        let character = dub.scene.character(id: dub.characterID)?.name ?? ""
        var parts = ["You as \(character)"]
        if let collaborator = dub.collaborator { parts.append("with \(collaborator.name)") }
        switch dub.progress {
        case .finished(let score):
            if let score { parts.append("timing \(score)") }
        case .draft(let completed, let total):
            parts.append("\(completed) of \(total) lines")
        }
        parts.append(dub.dateText)
        return parts.joined(separator: " · ")
    }

    private func visibilityBinding(for dub: ShelfDub) -> Binding<Bool> {
        Binding(
            get: { dub.visibility == .publicFeed },
            set: { model.setVisibility($0 ? .publicFeed : .privateShelf, for: dub.id) }
        )
    }
}
