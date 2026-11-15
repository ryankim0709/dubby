import SwiftUI

struct ContentView: View {
    let account: AccountModel
    @State private var tab: AppTab = .discover
    @State private var clips: LoadState<[LibraryClip]> = .loading
    @State private var dubs: LoadState<[SavedDub]> = .loading
    @State private var launch: DubFlowLaunch?
    @State private var isCoachPresented = false
    @State private var isAccountPresented = false

    private let libraryFolder = DubLibrary.defaultFolder
    private let history = LocalDubHistory(folder: DubLibrary.defaultFolder)

    private var streakDays: Int {
        guard case .loaded(let dubs) = dubs else { return 0 }
        return PracticeStats.currentStreak(dates: dubs.map(\.createdAt), today: .now, calendar: .current)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .discover:
                    DiscoverView(clips: clips, streakDays: streakDays, onDub: { launch = .scene($0) }, isSignedIn: account.phase.isSignedIn, onTalkToCoach: { isCoachPresented = true }, onAccount: { isAccountPresented = true }, onRetry: reloadClips)
                case .messages:
                    MessagesView()
                case .progress:
                    PracticeProgressView(dubs: dubs, folder: libraryFolder, account: account, onAccount: { isAccountPresented = true }, onRetry: reloadDubs)
                case .myDubs:
                    MyDubsView(dubs: dubs, folder: libraryFolder, onDelete: { dub in
                        _ = try await history.delete(dub)
                        reloadDubs()
                    }, onRetry: reloadDubs)
                }
            }
            // Attached to the tab roots only, so pushed screens keep their full-height layout.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                DubTabBar(selection: $tab, onCreate: { launch = .chooseScene })
            }
        }
        .fullScreenCover(item: $launch, onDismiss: reloadDubs) { launch in
            DubFlowView(launch: launch, clips: clips, onClose: { self.launch = nil })
        }
        .fullScreenCover(isPresented: $isCoachPresented) {
            // The dub result screen has no coach entry yet. When it gains one it should pass a
            // CoachPracticeContext only once its lines carry backend line ids; ScriptLine.id is a local index today.
            CoachView(practice: nil, tokens: AccountTokenProvider(account: account), onClose: { isCoachPresented = false })
        }
        .sheet(isPresented: $isAccountPresented) {
            AccountView(account: account, onClose: { isAccountPresented = false })
        }
        .task {
            await account.start()
        }
        .task {
            await loadDubs()
            await loadClips()
        }
        .preferredColorScheme(.dark)
    }

    private func reloadClips() {
        clips = .loading
        Task { await loadClips() }
    }

    private func loadClips() async {
        do {
            let bundled = try await MediaLibrary.loadClips(in: .main)
            // A clip bundled from Media/ wins over the Convex scene with the same slug, so it isn't downloaded.
            let bundledIDs = Set(bundled.map(\.sceneID))
            let remote = try await SceneCatalog.fetch(in: .main).filter { !bundledIDs.contains($0.slug) }
            let downloaded = try await SceneCatalog.loadClips(remote, folder: SceneCatalog.defaultFolder)
            clips = .loaded(LaunchConfiguration.current.ordering(MediaLibrary.sortedByTitle(bundled + downloaded)))
        } catch {
            clips = .failed("Scenes couldn't be read: \(error.localizedDescription)")
        }
    }

    private func reloadDubs() {
        Task { await loadDubs() }
    }

    private func loadDubs() async {
        do {
            dubs = .loaded(try await history.list())
        } catch {
            dubs = .failed("Saved dubs couldn't be read: \(error.localizedDescription)")
        }
    }
}

#Preview {
    ContentView(account: AccountModel(service: nil))
}
