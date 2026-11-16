import AVKit
import Combine
import ConvexMobile
import SwiftUI

/// Shared access/loading states for the existing Feed, Inbox and friend picker.
struct SocialContent<Content: View>: View {
    let account: AccountModel
    let state: LoadState<SocialSnapshot>
    let onAccount: () -> Void
    let onRetry: () -> Void
    @ViewBuilder let content: (SocialSnapshot) -> Content

    var body: some View {
        if !account.phase.isSignedIn {
            EmptyStateView(systemImage: "person.2", title: "Better with a scene partner", message: account.isAvailable ? "Sign in to find friends, send co-dub invitations and share your performances." : "Connect this build to the Dubby backend to use friends and co-dubs.")
            if account.isAvailable {
                Button("Sign in", action: onAccount).buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
            }
        } else {
            switch state {
            case .loading: ProgressView("Loading your friends…").frame(maxWidth: .infinity, minHeight: 180)
            case .failed(let message):
                EmptyStateView(systemImage: "wifi.exclamationmark", title: "Couldn't load your friends", message: message)
                Button("Try again", action: onRetry).buttonStyle(SecondaryButtonStyle())
                Button("Account", action: onAccount).frame(minHeight: 44)
            case .loaded(let snapshot): content(snapshot)
            }
        }
    }
}

struct SocialAvatar: View {
    let username: String
    var body: some View {
        Text(String(username.prefix(1)).uppercased())
            .dubFont(18, weight: .semibold)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .frame(width: 46, height: 46)
            .foregroundStyle(Palette.textPrimary)
            .background(Palette.surfaceRaised, in: Circle())
            .accessibilityHidden(true)
    }
}

struct FriendsView: View {
    let account: AccountModel
    let state: LoadState<SocialSnapshot>
    let onAccount: () -> Void
    let onRetry: () -> Void
    let onClose: () -> Void
    @State private var username = ""
    @State private var isWorking = false
    @State private var notice: String?
    @State private var removal: SocialPerson?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SocialContent(account: account, state: state, onAccount: onAccount, onRetry: onRetry) { snapshot in
                        Text("Your username: @\(snapshot.me.username)")
                            .dubFont(17, weight: .semibold)
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Friend's username", text: $username)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("friendUsername")
                            Button("Send friend request") {
                                perform { try await $0.requestFriend(username: username); username = ""; notice = "Friend request sent." }
                            }
                            .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
                            .disabled(isWorking || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("sendFriendRequest")
                            Text("Search by their Dubby username. Your contacts stay on your iPhone.")
                                .dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary)
                        }
                        ForEach(snapshot.requests) { request in
                            AdaptiveStack(rowAlignment: .center, spacing: 12) {
                                SocialAvatar(username: request.person.username)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("@\(request.person.username)").dubFont(17, weight: .semibold)
                                    Text(request.incoming ? "Wants to be your scene partner" : "Request sent").dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary)
                                }
                                Spacer()
                                if request.incoming {
                                    Button("Accept") { perform { try await $0.acceptFriend(id: request.id) } }
                                        .frame(minHeight: 44).disabled(isWorking)
                                    Button { perform { try await $0.removeFriend(personId: request.person.id) } } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                                        .accessibilityLabel("Decline request from \(request.person.username)")
                                } else {
                                    Button("Cancel") { perform { try await $0.removeFriend(personId: request.person.id) } }
                                        .frame(minHeight: 44).disabled(isWorking)
                                }
                            }
                        }
                        if snapshot.friends.isEmpty {
                            EmptyStateView(systemImage: "person.2", title: "Find your next co-star", message: "Add a friend by username. Once they accept, you can invite them to another role and see each other's shared dubs.")
                        }
                        ForEach(snapshot.friends) { friend in
                            AdaptiveStack(rowAlignment: .center, spacing: 12) {
                                SocialAvatar(username: friend.username)
                                Text("@\(friend.username)").dubFont(17, weight: .semibold)
                                Spacer()
                                Button { removal = friend } label: { Image(systemName: "person.crop.circle.badge.minus").frame(width: 44, height: 44) }
                                    .accessibilityLabel("Remove \(friend.username) from friends")
                            }
                        }
                    }
                    if isWorking { ProgressView("Updating friends…") }
                    if let notice { Text(notice).dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary).accessibilityIdentifier("friendNotice") }
                }
                .padding(20)
            }
            .screenBackground().foregroundStyle(Palette.textPrimary)
            .navigationTitle("Scene partners").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done", action: onClose) } }
            .confirmationDialog("Remove this friend? You'll stop seeing each other's friend-only posts. Existing co-dubs stay in your Inbox.", isPresented: removalPresented, titleVisibility: .visible) {
                if let removal { Button("Remove @\(removal.username)", role: .destructive) { perform { try await $0.removeFriend(personId: removal.id) } } }
            }
        }
        .preferredColorScheme(.dark).tint(Palette.accentText)
    }

    private var removalPresented: Binding<Bool> {
        Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
    }

    private func perform(_ operation: @escaping (SocialBackendClient) async throws -> Void) {
        isWorking = true
        notice = nil
        Task {
            defer { isWorking = false }
            do { try await operation(SocialBackendClient.configured(account: account)) }
            catch is CancellationError { return }
            catch { notice = error.localizedDescription }
        }
    }
}

struct SocialPlayback: View {
    let assetId: String
    let title: String
    let account: AccountModel
    let onReady: (AVPlayer) -> Void
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var reload = UUID()

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onDisappear { player.pause() }
            } else if let error {
                VStack(spacing: 12) {
                    Text(error).dubFont(14, weight: .regular)
                    Button("Try loading again") { reload = UUID() }.frame(minHeight: 44)
                }.padding(16)
            } else { ProgressView("Loading the dub…") }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityLabel(title)
        .task(id: reload) {
            error = nil
            do {
                let url = try await SocialBackendClient.configured(account: account).download(assetId: assetId)
                guard try await AVURLAsset(url: url).load(.isPlayable) else { throw SocialError.invalidResponse("The shared video isn't playable.") }
                try Task.checkCancellation()
                let player = AVPlayer(url: url)
                self.player = player
                onReady(player)
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct SocialRoomView: View {
    let id: String
    let account: AccountModel
    let viewerId: String?
    let onDub: (SocialDubLaunch) -> Void
    let onShowFeed: () -> Void
    let onClose: () -> Void
    @State private var room: LoadState<CoDubRoom> = .loading
    @State private var isWorking = false
    @State private var issue: String?
    @State private var refresh = UUID()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch room {
                    case .loading: ProgressView("Opening the invitation…")
                    case .failed(let message):
                        EmptyStateView(systemImage: "envelope.badge", title: "Couldn't open this co-dub", message: message)
                        Button("Try again") { refresh = UUID() }.buttonStyle(SecondaryButtonStyle())
                    case .loaded(let room): content(room)
                    }
                    if isWorking { ProgressView("Getting your scene ready…") }
                    if let issue { Text(issue).dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary).accessibilityIdentifier("coDubIssue") }
                }.padding(20)
            }
            .screenBackground().foregroundStyle(Palette.textPrimary)
            .navigationTitle("Co-dub").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) } }
        }
        .preferredColorScheme(.dark).tint(Palette.accentText)
        .task(id: refresh) { await watchRoom() }
    }

    @ViewBuilder
    private func content(_ room: CoDubRoom) -> some View {
        let isOwner = room.owner.id == viewerId
        let guestLines = room.script.lines.filter { $0.speakerId == room.script.guestCharacterId }.count
        Text(room.status == .completed ? "That's a wrap" : "Who's playing \(room.script.roleName(room.script.guestCharacterId))?")
            .dubFont(32, weight: .bold)
        Text(room.script.title).dubFont(22, weight: .semibold)
        if room.status == .completed, let result = room.resultAssetId {
            SocialPlayback(assetId: result, title: "Your combined co-dub", account: account) { $0.pause() }
        } else if room.status == .invited || room.status == .accepted {
            SocialPlayback(assetId: room.sourceAssetId, title: room.joinOnly ? "Scene to join" : "\(room.owner.username)'s saved performance", account: account) { $0.pause() }
        }
        performer(room.owner.username, role: room.script.roleName(room.script.ownerCharacterId), detail: "\(room.script.ownerLinesRecorded) \(room.script.ownerLinesRecorded == 1 ? "line" : "lines") recorded")
        performer(room.guest?.username ?? "Open role", role: room.script.roleName(room.script.guestCharacterId), detail: room.guestLinesRecorded.map { "\($0) \($0 == 1 ? "line" : "lines") recorded" } ?? room.status.title)
        switch room.status {
        case .invited, .accepted:
            if isOwner {
                Text(room.joinOnly ? "Send this link so your friend can join the scene and record their role." : "Your lines are saved. Send the invitation to your friend; they'll record the other character in their own time.")
                    .dubFont(17, weight: .regular).foregroundStyle(Palette.textSecondary)
                ShareLink(item: "dubby://invite/\(room.code)", message: Text("Play \(room.script.roleName(room.script.guestCharacterId)) in \(room.script.title) with me on Dubby.")) { Label("Share private invite", systemImage: "square.and.arrow.up") }
                    .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
                Text("Invite code: \(room.code)").dubFont(14, weight: .regular).textSelection(.enabled)
                Button("Cancel invitation", role: .destructive) { perform { try await $0.closeInvite(id: room.id) } }.frame(minHeight: 44)
            } else if room.guest?.id == viewerId {
                Text(room.joinOnly ? "You joined the dub. Record \(room.script.roleName(room.script.guestCharacterId)) in this scene. Your recording will be saved to your Shelf." : "Record \(guestLines) \(guestLines == 1 ? "line" : "lines") as \(room.script.roleName(room.script.guestCharacterId)). Your teammate's performance stays in the mix. Only you two can access it in Dubby until you both approve posting.")
                    .dubFont(17, weight: .regular).foregroundStyle(Palette.textSecondary)
                Button("Record \(room.script.roleName(room.script.guestCharacterId))") { prepareRole(room) }
                    .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control)).disabled(isWorking)
                    .accessibilityIdentifier("recordCoDubRole")
                Button("Decline invitation", role: .destructive) { perform { try await $0.closeInvite(id: room.id) } }.frame(minHeight: 44)
            }
        case .completed:
            Text("Posting shares the combined video with friends of either performer. Both of you must approve it.")
                .dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary)
            if room.published {
                Button("View friends feed", action: onShowFeed).buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
            } else {
                Button(room.approvedByMe ? "Waiting for your teammate's approval" : "Post to friends feed") { perform { try await $0.approvePost(id: room.id) } }
                    .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control)).disabled(isWorking || room.approvedByMe)
                    .accessibilityIdentifier("approveCoDubPost")
            }
            if room.approvedByMe {
                Button(room.published ? "Stop sharing this co-dub" : "Withdraw my posting approval") { perform { try await $0.withdrawApproval(id: room.id) } }
                    .frame(minHeight: 44).disabled(isWorking)
            }
            Button("Swap roles and go again") { prepareRematch(room) }
                .buttonStyle(SecondaryButtonStyle()).disabled(isWorking)
        case .declined, .cancelled:
            Text(room.status.title).dubFont(17, weight: .regular).foregroundStyle(Palette.textSecondary)
        }
    }

    private func performer(_ username: String, role: String, detail: String) -> some View {
        AdaptiveStack(rowAlignment: .center, spacing: 12) {
            SocialAvatar(username: username)
            VStack(alignment: .leading, spacing: 4) {
                Text(username).dubFont(20, weight: .semibold)
                Text("as \(role) · \(detail)").dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card))
    }

    private func prepareRole(_ room: CoDubRoom) {
        perform { client in
            if room.status == .invited { try await client.acceptInvite(id: room.id) }
            let video = try await client.download(assetId: room.sourceAssetId)
            let setup = try room.script.setup(video: video, characterId: room.script.guestCharacterId, protectedSpans: room.script.protectedSpans)
            onDub(SocialDubLaunch(setup: setup, completionRoom: room.joinOnly ? nil : room))
        }
    }

    private func prepareRematch(_ room: CoDubRoom) {
        perform { client in
            guard let assetId = room.resultAssetId else { throw SocialError.invalidResponse("This completed co-dub has no video.") }
            let video = try await client.download(assetId: assetId)
            let role = room.owner.id == viewerId ? room.script.guestCharacterId : room.script.ownerCharacterId
            onDub(SocialDubLaunch(setup: try room.script.setup(video: video, characterId: role, protectedSpans: []), completionRoom: nil))
        }
    }

    private func perform(_ operation: @escaping (SocialBackendClient) async throws -> Void) {
        isWorking = true
        issue = nil
        Task {
            defer { isWorking = false }
            do { try await operation(SocialBackendClient.configured(account: account)) }
            catch is CancellationError { return }
            catch { issue = error.localizedDescription }
        }
    }

    private func watchRoom() async {
        guard let client = account.convexClient else { room = .failed(SocialError.unavailable.localizedDescription); return }
        do {
            for try await value in client.subscribe(to: "social:room", with: ["id": id], yielding: CoDubRoom.self).values {
                _ = try CoDubLink.url(code: value.code)
                room = .loaded(value)
            }
        } catch is CancellationError { return }
        catch { room = .failed(error.localizedDescription) }
    }
}
