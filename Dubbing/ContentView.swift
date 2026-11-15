import SwiftUI

struct ContentView: View {
    let account: AccountModel
    let scoring: DubScoringModel?
    @State private var tab: AppTab = LaunchConfiguration.current.opensClubs ? .messages : .discover
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
        TabView(selection: tabSelection) {
            Tab("Discover", systemImage: "popcorn.fill", value: AppTab.discover) {
                DiscoverView(clips: clips, streakDays: streakDays, onDub: { launch = .scene($0) }, isSignedIn: account.phase.isSignedIn, onTalkToCoach: { isCoachPresented = true }, onAccount: { isAccountPresented = true }, onRetry: reloadClips)
            }
            Tab("Feed", systemImage: "play.rectangle.on.rectangle.fill", value: AppTab.feed) {
                CommunityFeedView(onCreate: { launch = .chooseScene })
            }
            Tab("Create", systemImage: "plus.circle.fill", value: AppTab.create) {
                Color.clear
            }
            Tab("Inbox", systemImage: "tray.fill", value: AppTab.messages) {
                NavigationStack { MessagesView(account: account, scoring: scoring) }
            }
            Tab("Shelf", systemImage: "books.vertical.fill", value: AppTab.myDubs) {
                NavigationStack {
                    MyDubsView(dubs: dubs, folder: libraryFolder, account: account, onAccount: { isAccountPresented = true }, onDelete: { dub in
                        _ = try await history.delete(dub)
                        reloadDubs()
                    }, onRetry: reloadDubs)
                }
            }
        }
        .tint(Palette.textPrimary)
        .fullScreenCover(item: $launch, onDismiss: reloadDubs) { launch in
            DubFlowView(launch: launch, clips: clips, account: account, scoring: scoring, onRetry: reloadClips, onClose: { self.launch = nil })
        }
        .fullScreenCover(isPresented: $isCoachPresented) {
            // The dub result screen has no coach entry yet. When it gains one it should pass a
            // CoachPracticeContext only once its lines carry backend line ids; ScriptLine.id is a local index today.
            CoachAccessView(account: account, onClose: { isCoachPresented = false })
        }
        .sheet(isPresented: $isAccountPresented) {
            AccountView(account: account, onClose: { isAccountPresented = false })
        }
        .task {
            await loadDubs()
            await loadClips()
        }
        .preferredColorScheme(.dark)
    }

    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { tab },
            set: { selected in
                if selected == .create {
                    launch = .chooseScene
                } else {
                    tab = selected
                }
            }
        )
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
            let remote = try await SceneCatalog.fetch(in: .main)
            let local = bundled.map { clip in
                LibraryClip(url: clip.url, title: clip.title, durationSeconds: clip.durationSeconds, origin: clip.origin, details: remote.first { $0.slug == clip.sceneID }?.details ?? clip.details)
            }
            let downloaded = try await SceneCatalog.loadClips(remote.filter { !bundledIDs.contains($0.slug) }, folder: SceneCatalog.defaultFolder)
            clips = .loaded(LaunchConfiguration.current.ordering(MediaLibrary.sortedByTitle(local + downloaded)))
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
    ContentView(account: AccountModel(service: nil), scoring: nil)
}
