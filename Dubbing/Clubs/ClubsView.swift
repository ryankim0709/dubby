import SwiftUI

struct ClubsView: View {
    let account: AccountModel
    @State private var feed: LoadState<ClubFeed> = .loading
    @State private var scene: LoadState<CuratedScene> = .loading
    @State private var refreshID = UUID()
    @State private var isPractising = false
    @State private var isChoosingDub = false
    @State private var reply: ClubPost?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Dub Clubs").dubFont(28, weight: .bold).padding(.top, 8)
                LoadStateContent(state: feed, failureIdentifier: "clubLoadFailed", retry: { refreshID = UUID() }) { feed in
                    VStack(alignment: .leading, spacing: 24) {
                        Label(feed.members.map(\.displayName).joined(separator: " & "), systemImage: "person.2")
                            .font(.subheadline).foregroundStyle(Palette.textSecondary)
                        challenge(feed.challenge)
                        HStack {
                            Text("Performances").font(.title3.weight(.semibold))
                            Spacer()
                            Button("Share a dub") { isChoosingDub = true }
                                .frame(minHeight: 44).accessibilityIdentifier("clubChooseDub")
                        }
                        if feed.performances.isEmpty {
                            EmptyStateView(systemImage: "film", title: "Be first on the bridge", message: "Dub the challenge scene, then share your performance here.")
                        }
                        ForEach(feed.performances) { post in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(post.authorId == feed.viewerId ? "You · \(post.authorName)" : post.authorName).font(.headline)
                                ClubMediaPlayer(url: post.mediaURL, kind: .video)
                                if !post.caption.isEmpty { Text(post.caption).font(.body) }
                                ForEach(feed.feedback(for: post)) { feedback in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Label("\(feedback.authorName)'s feedback", systemImage: "waveform").font(.subheadline.weight(.medium))
                                        ClubMediaPlayer(url: feedback.mediaURL, kind: .voice)
                                        if !feedback.caption.isEmpty { Text(feedback.caption).font(.subheadline).foregroundStyle(Palette.textSecondary) }
                                    }
                                    .padding(.leading, 12)
                                }
                                Button { reply = post } label: { Label("Voice feedback", systemImage: "mic") }
                                    .buttonStyle(OutlineCapsuleButtonStyle())
                                    .frame(minHeight: 44)
                                    .accessibilityIdentifier("clubReply-\(post.id)")
                                Divider().overlay(Palette.divider).padding(.top, 12)
                            }
                        }
                        Text("Private demo club · Media shared through Whop").font(.footnote).foregroundStyle(Palette.textSecondary)
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 16).padding(.bottom, 24)
            .frame(maxWidth: .infinity)
            .containerIdentifier("dubClubsScreen")
        }
        .background(Palette.background).foregroundStyle(Palette.textPrimary).tint(Palette.accentText)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await refresh() }
        .task(id: refreshID) {
            guard scenePhase == .active else { return }
            await loadScene()
            while !Task.isCancelled {
                guard await refresh() else { return }
                guard await pause(for: .seconds(5)) else { return }
            }
        }
        .onChange(of: scenePhase) { _, _ in refreshID = UUID() }
        .onChange(of: account.phase) { _, _ in feed = .loading; refreshID = UUID() }
        .fullScreenCover(isPresented: $isPractising, onDismiss: { refreshID = UUID() }) {
            if case .loaded(let scene) = scene { ClubChallengePractice(account: account, scene: scene) }
        }
        .sheet(isPresented: $isChoosingDub) {
            if case .loaded(let feed) = feed {
                ClubSavedDubPicker(account: account, challenge: feed.challenge, onShared: { refreshID = UUID() })
            }
        }
        .sheet(item: $reply) { post in
            ClubVoiceFeedback(account: account, post: post, onShared: { refreshID = UUID() })
        }
    }

    private func challenge(_ challenge: ClubChallenge) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if case .loaded(let scene) = scene {
                VideoThumbnail(url: scene.videoURL).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 16))
            }
            Text(challenge.title).font(.title2.weight(.semibold))
            Text(challenge.sceneTitle).font(.headline).foregroundStyle(Palette.accentText)
            Text(challenge.prompt).font(.body).foregroundStyle(Palette.textSecondary)
            LoadStateContent(state: scene, failureIdentifier: "clubSceneFailed", retry: { Task { await loadScene() } }) { _ in
                Button("Dub this challenge") { isPractising = true }
                    .buttonStyle(PrimaryButtonStyle(cornerRadius: 16)).accessibilityIdentifier("clubStartChallenge")
            }
        }
    }

    @discardableResult private func refresh() async -> Bool {
        do { feed = .loaded(try await ClubClient.configured(account: account).feed()); return true }
        catch is CancellationError { return false }
        catch { feed = .failed(error.localizedDescription); return false }
    }

    private func loadScene() async {
        let catalog = await CuratedSceneLoader.loadCatalog(in: .main)
        if let scene = catalog.scene(withID: "tears-of-steel-bridge") { self.scene = .loaded(scene) }
        else { scene = .failed(catalog.failures.first?.error.localizedDescription ?? "The bridge challenge isn't included in this build.") }
    }
}

private struct ClubSavedDubPicker: View {
    let account: AccountModel
    let challenge: ClubChallenge
    let onShared: () -> Void
    @State private var dubs: LoadState<[SavedDub]> = .loading
    @State private var selection: ClubMediaDraft?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(challenge.sceneTitle).font(.headline)
                    Text("Choose a finished dub of this challenge. You'll preview it before sharing.").foregroundStyle(Palette.textSecondary)
                    LoadStateContent(state: dubs, failureIdentifier: "clubSavedDubsFailed", retry: { Task { await load() } }) { dubs in
                        if dubs.isEmpty {
                            EmptyStateView(systemImage: "film", title: "Dub the challenge first", message: "Use Dub this challenge in your club, finish a performance, then share it here.")
                        }
                        ForEach(dubs) { dub in
                            Button {
                                selection = ClubMediaDraft(url: DubLibrary.videoURL(for: dub, in: DubLibrary.defaultFolder), kind: .video, title: "\(dub.sceneTitle) · \(dub.characterName)", replyToMessageId: nil)
                            } label: {
                                HStack(spacing: 12) {
                                    VideoThumbnail(url: DubLibrary.videoURL(for: dub, in: DubLibrary.defaultFolder)).frame(width: 96, height: 60).clipShape(RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 4) { Text(dub.characterName).font(.headline); Text(dub.createdAt, style: .date).font(.subheadline) }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                                .padding(.vertical, 8).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("clubSelectDub-\(dub.id)")
                        }
                    }
                }.padding(20)
            }
            .background(Palette.background).foregroundStyle(Palette.textPrimary)
            .navigationTitle("Share a dub").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .tint(Palette.accentText).preferredColorScheme(.dark)
        .task { await load() }
        .sheet(item: $selection) { draft in ClubComposer(account: account, draft: draft, onShared: { onShared(); dismiss() }) }
    }

    private func load() async {
        do { dubs = .loaded(try await LocalDubHistory(folder: DubLibrary.defaultFolder).list().filter { $0.sceneTitle == challenge.sceneTitle }) }
        catch { dubs = .failed(error.localizedDescription) }
    }
}
