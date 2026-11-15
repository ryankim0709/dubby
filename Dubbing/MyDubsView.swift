import AVKit
import SwiftUI

struct MyDubsView: View {
    let dubs: LoadState<[SavedDub]>
    let folder: URL
    let account: AccountModel
    let onAccount: () -> Void
    let onDelete: (SavedDub) async throws -> Void
    let onRetry: () -> Void
    @State private var playing: SavedDub?
    @State private var pendingDelete: SavedDub?
    @State private var deleteFailure: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                profileHeader
                AdaptiveStack(rowAlignment: .center, spacing: 8) {
                    Text("Your shelf")
                        .dubFont(24, weight: .bold)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                    NavigationLink {
                        PracticeProgressView(dubs: dubs, folder: folder, account: account, onAccount: onAccount, onRetry: onRetry)
                    } label: {
                        Label("Progress", systemImage: "chart.bar")
                            .dubFont(14, weight: .semibold)
                            .foregroundStyle(Palette.textSecondary)
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("tab-progress")
                }
                LoadStateContent(state: dubs, failureIdentifier: "myDubsLoadFailed", retry: onRetry) { dubs in
                    if dubs.isEmpty {
                        EmptyStateView(
                            systemImage: "film",
                            title: "Nothing on this shelf yet",
                            message: "Your finished scenes land here. Find your first role in Discover."
                        )
                        .accessibilityIdentifier("myDubsEmpty")
                    } else {
                        Text("\(dubs.count) \(dubs.count == 1 ? "dub" : "dubs") saved on this iPhone")
                            .dubFont(14, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                            .overlay { StateCarriers(items: [StateCarrier(identifier: "myDubsCount", value: "\(dubs.count)")]) }
                        LazyVGrid(
                            columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 104), spacing: 14)],
                            spacing: 28
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
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .containerIdentifier("myDubsScreen")
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Account", systemImage: "gearshape", action: onAccount)
                    .accessibilityIdentifier("shelfAccount")
            }
        }
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

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .dubFont(58, weight: .light)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(profileName)
                        .dubFont(30, weight: .bold)
                        .foregroundStyle(Palette.textPrimary)
                    Text("A shelf full of scenes, in your voice.")
                        .dubFont(15, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            if case .loaded(let saved) = dubs {
                HStack(spacing: 24) {
                    Label("\(saved.count) dubs", systemImage: "film.stack")
                    Label("\(PracticeStats.currentStreak(dates: saved.map(\.createdAt), today: .now, calendar: .current)) day streak", systemImage: "flame")
                }
                .dubFont(15, weight: .medium)
                .foregroundStyle(Palette.textSecondary)
                .monospacedDigit()
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var profileName: String {
        if case .signedIn(let profile) = account.phase { return profile.displayName }
        return "Your shelf"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VideoThumbnail(url: video)
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(dub.sceneTitle.uppercased())
                        .displayFont(25)
                        .foregroundStyle(.white)
                        .lineLimit(4)
                        .minimumScaleFactor(0.6)
                        .padding(12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.35)).frame(width: 5)
                }
            Text("as \(dub.characterName)")
                .dubFont(14, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Text("\(dub.linesDubbed)/\(dub.totalLines) lines")
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
                .monospacedDigit()
            LinearGradient(colors: [Palette.shelfWood, Palette.shelfWoodShadow], startPoint: .top, endPoint: .bottom)
                .frame(height: 8)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(dub.sceneTitle), as \(dub.characterName), \(dub.linesDubbed) of \(dub.totalLines) lines")
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
                        .accessibilityIdentifier("savedDubDone")
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
            .containerIdentifier("savedDubPlayer")
        }
        .background(Palette.background)
        .preferredColorScheme(.dark)
    }
}
