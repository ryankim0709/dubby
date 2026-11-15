import SwiftUI

struct ContentView: View {
    @State private var tab: AppTab = .discover
    @State private var clips: LoadState<[LibraryClip]> = .loading
    @State private var dubs: LoadState<[SavedDub]> = .loading
    @State private var launch: DubFlowLaunch?
    @State private var isCoachPresented = false

    private let libraryFolder = DubLibrary.defaultFolder

    private var streakDays: Int {
        guard case .loaded(let dubs) = dubs else { return 0 }
        return PracticeStats.currentStreak(dates: dubs.map(\.createdAt), today: .now, calendar: .current)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .discover:
                    DiscoverView(clips: clips, streakDays: streakDays, onDub: { launch = .scene($0) }, onTalkToCoach: { isCoachPresented = true }, onRetry: reloadClips)
                case .messages:
                    MessagesView()
                case .progress:
                    PracticeProgressView(dubs: dubs, folder: libraryFolder, onRetry: reloadDubs)
                case .myDubs:
                    MyDubsView(dubs: dubs, folder: libraryFolder, onChange: reloadDubs, onRetry: reloadDubs)
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
            CoachView(onClose: { isCoachPresented = false })
        }
        .task {
            reloadDubs()
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
            clips = .loaded(try await MediaLibrary.loadClips(in: .main))
        } catch {
            clips = .failed("Scenes couldn't be read: \(error.localizedDescription)")
        }
    }

    private func reloadDubs() {
        do {
            dubs = .loaded(try DubLibrary.load(from: libraryFolder))
        } catch {
            dubs = .failed("Saved dubs couldn't be read: \(error.localizedDescription)")
        }
    }
}

#Preview {
    ContentView()
}
