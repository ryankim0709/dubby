import AVKit
import SwiftUI

struct MyDubsView: View {
    let dubs: LoadState<[SavedDub]>
    let folder: URL
    let account: AccountModel
    let onAccount: () -> Void
    let onDelete: (SavedDub) async throws -> Void
    let onRetry: () -> Void
    @State private var filter: ShelfFilter = .all
    @State private var playing: SavedDub?
    @State private var pendingDelete: SavedDub?
    @State private var deleteFailure: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum ShelfFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case coDubs = "Co-dubs"
        case drafts = "Drafts"

        var id: Self { self }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                profileHeader
                Picker("Show", selection: $filter) {
                    ForEach(ShelfFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
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
                    if dubs.isEmpty || filter != .all {
                        EmptyStateView(
                            systemImage: "film",
                            title: "Nothing on this shelf yet",
                            message: filter == .all ? "Your finished scenes land here. Find your first role in Discover." : "You haven't saved any \(filter.rawValue.lowercased()) yet."
                        )
                        .accessibilityIdentifier("myDubsEmpty")
                    } else {
                        Text("\(dubs.count) \(dubs.count == 1 ? "dub" : "dubs") saved on this iPhone")
                            .dubFont(14, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                            .overlay { StateCarriers(items: [StateCarrier(identifier: "myDubsCount", value: "\(dubs.count)")]) }
                        shelves(dubs)
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
                    Text(account.phase.isSignedIn ? "@\(profileName)" : "Your dubs, in one place.")
                        .dubFont(15, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            if case .loaded(let saved) = dubs {
                AdaptiveStack(rowAlignment: .firstTextBaseline, spacing: 24) {
                    stat(value: "\(saved.count)", label: "dubs")
                    stat(value: "\(PracticeStats.currentStreak(dates: saved.map(\.createdAt), today: .now, calendar: .current))", label: "day streak")
                }
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
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

    private func shelves(_ dubs: [SavedDub]) -> some View {
        let perShelf = dynamicTypeSize.isAccessibilitySize ? 1 : 3
        let rows = stride(from: 0, to: dubs.count, by: perShelf).map { Array(dubs[$0..<min($0 + perShelf, dubs.count)]) }
        return VStack(spacing: 28) {
            ForEach(rows, id: \.first?.id) { row in
                VStack(spacing: 0) {
                    HStack(alignment: .bottom, spacing: 14) {
                        ForEach(row) { dub in
                            Button { playing = dub } label: {
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
                        ForEach(row.count..<perShelf, id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 14)
                    VStack(spacing: 0) {
                        Rectangle().fill(Palette.accent.opacity(0.25)).frame(height: 1)
                        LinearGradient(colors: [Palette.shelfWood, Palette.shelfWoodShadow], startPoint: .top, endPoint: .bottom)
                            .frame(height: 10)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .shadow(color: .black.opacity(0.7), radius: 8, x: 0, y: 8)
                    .accessibilityHidden(true)
                }
            }
        }
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
        VideoThumbnail(url: video)
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(dub.sceneTitle.uppercased())
                        .displayFont(20)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                    Text("as \(dub.characterName)")
                        .dubFont(11, weight: .semibold)
                }
                .foregroundStyle(Palette.textPrimary)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .padding(.leading, 12)
                .padding([.trailing, .bottom], 7)
            }
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    Rectangle().fill(.black.opacity(0.4)).frame(width: 5)
                    Rectangle().fill(.white.opacity(0.18)).frame(width: 1)
                }
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "lock.fill")
                    .dubFont(11, weight: .bold)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 22, height: 22)
                    .background(.black.opacity(0.5), in: Circle())
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 5)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(dub.sceneTitle), as \(dub.characterName), \(dub.linesDubbed) of \(dub.totalLines) lines, private")
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
