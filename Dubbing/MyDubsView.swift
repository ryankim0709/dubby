import AVKit
import SwiftUI

struct MyDubsView: View {
    let dubs: LoadState<[SavedDub]>
    let folder: URL
    let onChange: () -> Void
    let onRetry: () -> Void
    @State private var playing: SavedDub?
    @State private var pendingDelete: SavedDub?
    @State private var deleteFailure: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("My Dubs")
                    .dubFont(24, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.top, 8)
                LoadStateContent(state: dubs, retry: onRetry) { dubs in
                    if dubs.isEmpty {
                        EmptyStateView(
                            systemImage: "film",
                            title: "No dubs yet",
                            message: "Dub a scene from Discover and it shows up here, ready to watch and share."
                        )
                    } else {
                        Text("\(dubs.count) \(dubs.count == 1 ? "dub" : "dubs") saved on this iPhone")
                            .dubFont(14, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                        LazyVGrid(
                            columns: adaptiveGridColumns(spacing: 8, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize),
                            spacing: 16
                        ) {
                            ForEach(dubs) { dub in
                                Button {
                                    playing = dub
                                } label: {
                                    SavedDubCard(dub: dub, video: DubLibrary.videoURL(for: dub, in: folder))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = dub }
                                }
                                .accessibilityAction(named: "Delete") { pendingDelete = dub }
                            }
                        }
                    }
                }
                if let deleteFailure {
                    Text(deleteFailure)
                        .dubFont(14, weight: .regular)
                        .foregroundStyle(Palette.streak)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .background(Palette.background)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $playing) { dub in
            SavedDubPlayer(dub: dub, video: DubLibrary.videoURL(for: dub, in: folder))
        }
        .confirmationDialog(
            "Delete this dub?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { dub in
            Button("Delete dub", role: .destructive) { delete(dub) }
        } message: { dub in
            Text("\(dub.sceneTitle) as \(dub.characterName) will be removed from this iPhone.")
        }
    }

    private func delete(_ dub: SavedDub) {
        do {
            _ = try DubLibrary.delete(dub, in: folder)
            deleteFailure = nil
        } catch {
            deleteFailure = "Couldn't delete that dub: \(error.localizedDescription)"
        }
        pendingDelete = nil
        onChange()
    }
}

private struct SavedDubCard: View {
    let dub: SavedDub
    let video: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VideoThumbnail(url: video)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.bottom, 8)
            Text(dub.sceneTitle)
                .dubFont(14, weight: .medium)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Text("as \(dub.characterName) · \(dub.createdAt.formatted(.relative(presentation: .named)))")
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
            Text("\(dub.linesDubbed)/\(dub.totalLines) lines in your voice")
                .dubFont(12, weight: .semibold)
                .foregroundStyle(Palette.accentText)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct SavedDubPlayer: View {
    let dub: SavedDub
    let video: URL
    @State private var player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    init(dub: SavedDub, video: URL) {
        self.dub = dub
        self.video = video
        _player = State(initialValue: AVPlayer(url: video))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dub.sceneTitle)
                            .dubFont(18, weight: .semibold)
                            .foregroundStyle(Palette.textPrimary)
                        Text("as \(dub.characterName)")
                            .dubFont(14, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .dubFont(16, weight: .semibold)
                        .foregroundStyle(Palette.accentText)
                        .frame(minWidth: 44, minHeight: 44)
                }
                VideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
                TakeSummaryView(measurements: dub.takeMeasurements)
                ShareLink(item: video) {
                    Label("Share dub", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle(cornerRadius: 16))
                .accessibilityIdentifier("shareSavedDub")
            }
            .padding(16)
        }
        .background(Palette.background)
        .preferredColorScheme(.dark)
    }
}
