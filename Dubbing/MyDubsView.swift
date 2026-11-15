import AVKit
import SwiftUI

struct MyDubsView: View {
    let dubs: LoadState<[SavedDub]>
    let folder: URL
    let onDelete: (SavedDub) async throws -> Void
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
                LoadStateContent(state: dubs, failureIdentifier: "myDubsLoadFailed", retry: onRetry) { dubs in
                    if dubs.isEmpty {
                        EmptyStateView(
                            systemImage: "film",
                            title: "No dubs yet",
                            message: "Dub a scene from Discover and it shows up here, ready to watch and share."
                        )
                        .accessibilityIdentifier("myDubsEmpty")
                    } else {
                        Text("\(dubs.count) \(dubs.count == 1 ? "dub" : "dubs") saved on this iPhone")
                            .dubFont(14, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                            .overlay { StateCarriers(items: [StateCarrier(identifier: "myDubsCount", value: "\(dubs.count)")]) }
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
                                .accessibilityIdentifier("savedDub-\(dub.id.uuidString)")
                                .accessibilityValue("\(dub.linesDubbed) of \(dub.totalLines)")
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
            .containerIdentifier("myDubsScreen")
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
                .accessibilityIdentifier("confirmDeleteDub")
        } message: { dub in
            Text("\(dub.sceneTitle) as \(dub.characterName) will be removed from this iPhone.")
        }
    }

    private func delete(_ dub: SavedDub) {
        pendingDelete = nil
        Task {
            do {
                try await onDelete(dub)
                deleteFailure = nil
            } catch {
                deleteFailure = "Couldn't delete that dub: \(error.localizedDescription)"
            }
        }
    }
}

private struct SavedDubCard: View {
    let dub: SavedDub
    let video: URL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VideoThumbnail(url: video)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: GlassMetrics.minimumTarget, height: GlassMetrics.minimumTarget)
                        .dubGlass(in: Circle())
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.bottom, 8)
            Text(dub.sceneTitle)
                .dubFont(14, weight: .medium)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            Text("as \(dub.characterName) · \(dub.createdAt.formatted(.relative(presentation: .named)))")
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
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
                        .buttonStyle(.dubSecondary)
                        .accessibilityIdentifier("savedDubDone")
                        .fixedSize(horizontal: true, vertical: false)
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
                .buttonStyle(.dubPrimary)
                .accessibilityIdentifier("shareSavedDub")
            }
            .padding(16)
            .containerIdentifier("savedDubPlayer")
        }
        .background(Palette.background)
        .preferredColorScheme(.dark)
    }
}
