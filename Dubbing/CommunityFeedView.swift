import AVFoundation
import SwiftUI

struct CommunityFeedView: View {
    let account: AccountModel
    let state: LoadState<SocialSnapshot>
    let onAccount: () -> Void
    let onRetry: () -> Void
    let onFriends: () -> Void
    let onCreate: () -> Void
    @State private var playing: SocialPost?
    @State private var removing: SocialPost?
    @State private var issue: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    SocialContent(account: account, state: state, onAccount: onAccount, onRetry: onRetry) { snapshot in
                        if snapshot.posts.isEmpty {
                            EmptyStateView(systemImage: "play.rectangle.on.rectangle", title: "A scene worth sharing", message: "Dubs shared by you and your accepted friends appear here. Make one yourself or invite a friend to another role.")
                            Button("Create a dub", action: onCreate).buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
                            Button("Find scene partners", action: onFriends).buttonStyle(SecondaryButtonStyle())
                        }
                        ForEach(snapshot.posts) { post in postCard(post, viewer: snapshot.me) }
                    }
                    if let issue { Text(issue).dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary) }
                }.padding(20)
            }
            .background(.black).foregroundStyle(Palette.textPrimary)
            .navigationTitle("Feed").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Friends", systemImage: "person.2", action: onFriends).labelStyle(.iconOnly) } }
            .confirmationDialog("Stop sharing this dub with friends?", isPresented: removalPresented, titleVisibility: .visible) {
                if let removing { Button("Stop sharing", role: .destructive) { unpublish(removing) } }
            }
        }
        .onDisappear { playing = nil }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playing = nil }
        }
    }

    private func postCard(_ post: SocialPost, viewer: SocialPerson) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AdaptiveStack(rowAlignment: .center, spacing: 12) {
                SocialAvatar(username: post.owner.username)
                VStack(alignment: .leading, spacing: 4) {
                    Text(post.guest.map { "@\(post.owner.username) + @\($0.username)" } ?? "@\(post.owner.username)").dubFont(17, weight: .semibold)
                    Text(post.coDubId == nil ? "Shared a dub · Friends only" : "Made a co-dub · Friends only").dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                if post.owner.id == viewer.id || post.guest?.id == viewer.id {
                    Menu { Button("Stop sharing", role: .destructive) { removing = post } } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .accessibilityLabel("Options for \(post.title)")
                }
            }
            Group {
                if playing?.id == post.id {
                    SocialPlayback(assetId: post.assetId, title: post.title, account: account) { $0.play() }
                } else {
                    Button { playing = post } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: Radius.poster).fill(Palette.surface)
                            VStack(spacing: 16) {
                                Image(systemName: "play.circle.fill").font(.system(size: 48)).accessibilityHidden(true)
                                Text(post.title).displayFont(36).multilineTextAlignment(.center)
                            }.padding(20)
                        }.aspectRatio(16 / 9, contentMode: .fit)
                    }.buttonStyle(.plain).accessibilityLabel("Play \(post.title), shared by \(post.owner.username)")
                }
            }
            .onScrollVisibilityChange(threshold: 0.01) { isVisible in
                if !isVisible, playing?.id == post.id { playing = nil }
            }
            Text("\(post.owner.username) as \(post.characterName) · \(post.linesRecorded) \(post.linesRecorded == 1 ? "line" : "lines")").dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary)
            if let guest = post.guest, let character = post.guestCharacterName, let lines = post.guestLinesRecorded {
                Text("\(guest.username) as \(character) · \(lines) \(lines == 1 ? "line" : "lines")").dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var removalPresented: Binding<Bool> { Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }) }

    private func unpublish(_ post: SocialPost) {
        Task {
            do { try await SocialBackendClient.configured(account: account).unpublish(id: post.id) }
            catch { issue = error.localizedDescription }
        }
    }
}
