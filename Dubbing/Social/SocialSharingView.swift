import Combine
import ConvexMobile
import SwiftUI

private enum SocialSharePhase {
    case editing
    case uploading
    case posted
}

struct SocialSharingView: View {
    let source: SocialDubSource
    let account: AccountModel
    let onClose: () -> Void
    @State private var state: LoadState<SocialSnapshot> = .loading
    @State private var guestCharacterId: Int
    @State private var recipientId: String?
    @State private var phase: SocialSharePhase = .editing
    @State private var issue: String?
    @State private var assetId: String?
    @State private var isInviting = false
    @State private var isAccountPresented = false
    @State private var refresh = UUID()

    init(source: SocialDubSource, account: AccountModel, onClose: @escaping () -> Void) {
        self.source = source
        self.account = account
        self.onClose = onClose
        _guestCharacterId = State(initialValue: source.setup.script.speakers.first { $0.id != source.setup.characterID }?.id ?? source.setup.characterID)
    }

    private var isWorking: Bool { if case .uploading = phase { return true }; return isInviting }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SocialContent(account: account, state: state, onAccount: { isAccountPresented = true }, onRetry: { refresh = UUID() }) { snapshot in
                        switch phase {
                        case .editing, .uploading: editor(snapshot)
                        case .posted:
                            EmptyStateView(systemImage: "checkmark.circle", title: "Shared with your friends", message: "Your dub is now in the friends feed. You can stop sharing it from the post's menu.")
                            Button("Done", action: onClose).buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
                        }
                    }
                    if let issue { Text(issue).dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary).accessibilityIdentifier("socialShareError") }
                }.padding(20)
            }
            .screenBackground().foregroundStyle(Palette.textPrimary)
            .navigationTitle("Share your scene").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose).disabled(isWorking) } }
        }
        .preferredColorScheme(.dark).tint(Palette.accentText)
        .interactiveDismissDisabled(isWorking)
        .sheet(isPresented: $isAccountPresented) { AccountView(account: account, onClose: { isAccountPresented = false }) }
        .task(id: refresh) { await watchFriends() }
    }

    private func editor(_ snapshot: SocialSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Who's playing \(source.setup.script.speaker(withID: guestCharacterId)?.name ?? "the next character")?")
                .dubFont(32, weight: .bold)
            Text("Your lines as \(source.setup.script.speaker(withID: source.setup.characterID)?.name ?? "your character") are saved.")
                .dubFont(17, weight: .regular).foregroundStyle(Palette.textSecondary)
            VideoThumbnail(url: source.video)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    Text(source.setup.clip.title).displayFont(32).padding(16).shadow(color: .black, radius: 2, x: 0, y: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.poster))
            if source.setup.script.speakers.count > 1 {
                Picker("Your friend's role", selection: $guestCharacterId) {
                    ForEach(source.setup.script.speakers.filter { $0.id != source.setup.characterID }) { role in Text(role.name).tag(role.id) }
                }
                .pickerStyle(.menu).disabled(isWorking)
                Button { recipientId = nil } label: {
                    AdaptiveStack(rowAlignment: .center, spacing: 12) {
                        Image(systemName: "message").dynamicTypeSize(...DynamicTypeSize.xxxLarge).frame(width: 46, height: 46).background(Palette.surfaceRaised, in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Choose someone in Messages").dubFont(17, weight: .semibold)
                            Text("Your friend opens the invitation to record the other role in Dubby.").dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary)
                        }
                        Spacer()
                        Image(systemName: recipientId == nil ? "checkmark.circle.fill" : "circle")
                    }.frame(minHeight: 60)
                }.buttonStyle(.plain).disabled(isWorking)
                ForEach(snapshot.friends) { friend in
                    Button { recipientId = friend.id } label: {
                        AdaptiveStack(rowAlignment: .center, spacing: 12) {
                            SocialAvatar(username: friend.username)
                            Text("@\(friend.username)").dubFont(17, weight: .semibold)
                            Spacer()
                            Image(systemName: recipientId == friend.id ? "checkmark.circle.fill" : "circle")
                        }.frame(minHeight: 60)
                    }.buttonStyle(.plain).disabled(isWorking)
                    Divider().overlay(Palette.hairline)
                }
                Text("Share uploads your saved video and script, then opens Messages so you can choose who plays \(source.setup.script.speaker(withID: guestCharacterId)?.name ?? "the other character"). Both performers approve before the combined dub appears in friends' feeds.")
                    .dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary)
                CoDubInvitationButton(source: source, account: account, guestCharacterId: guestCharacterId, recipientId: recipientId, title: "Share", isWorking: $isInviting)
                    .id("\(guestCharacterId)-\(recipientId ?? "messages")")
                    .disabled(isWorking)
            } else {
                Text("This scene has one character. Choose a scene with another role to co-dub with a friend.")
                    .dubFont(17, weight: .regular).foregroundStyle(Palette.textSecondary)
            }
            Divider().overlay(Palette.hairline)
            Text("Or share this performance as it is.").dubFont(17, weight: .semibold)
            Text("Posting uploads this video and shares it with your accepted Dubby friends.")
                .dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary)
            Button("Post my dub to friends feed") { postSolo() }
                .buttonStyle(SecondaryButtonStyle()).disabled(isWorking)
                .accessibilityIdentifier("postSoloDub")
            if isWorking { ProgressView("Keep Dubby open while the video uploads.") }
        }
    }

    private func uploadedVideo(using client: SocialBackendClient) async throws -> String {
        if let assetId { return assetId }
        let id = try await client.upload(video: source.video)
        assetId = id
        return id
    }

    private func postSolo() {
        phase = .uploading
        issue = nil
        Task {
            do {
                let client = try SocialBackendClient.configured(account: account)
                let id = try await uploadedVideo(using: client)
                try await client.postSolo(assetId: id, title: source.setup.clip.title, characterName: source.setup.script.speaker(withID: source.setup.characterID)?.name ?? "Character", linesRecorded: source.takes.count)
                phase = .posted
            } catch {
                phase = .editing
                issue = error.localizedDescription
            }
        }
    }

    private func watchFriends() async {
        guard let client = account.convexClient else { state = .failed(SocialError.unavailable.localizedDescription); return }
        do {
            for try await snapshot in client.subscribe(to: "social:snapshot", yielding: SocialSnapshot.self).values { state = .loaded(snapshot) }
        } catch is CancellationError { return }
        catch { state = .failed(error.localizedDescription) }
    }
}

struct CompleteCoDubView: View {
    let room: CoDubRoom
    let video: URL
    let linesRecorded: Int
    let account: AccountModel
    @State private var assetId: String?
    @Binding var isWorking: Bool
    @State private var completed = false
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your two performances, one scene.").dubFont(22, weight: .semibold)
            Text("Upload the combined video so @\(room.owner.username) can watch it. You both approve before posting to friends.")
                .dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary)
            Button(completed ? "Co-dub delivered to your teammate" : isWorking ? "Uploading the co-dub…" : "Finish co-dub with @\(room.owner.username)") { complete() }
                .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
                .disabled(isWorking || completed || linesRecorded != room.script.lines.filter { $0.speakerId == room.script.guestCharacterId }.count)
                .accessibilityIdentifier("completeCoDub")
            if completed { Text("Open your Inbox to watch together, approve posting, or swap roles.").dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary) }
            if let issue { Text(issue).dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary) }
        }
    }

    private func complete() {
        isWorking = true
        issue = nil
        Task {
            defer { isWorking = false }
            do {
                let client = try SocialBackendClient.configured(account: account)
                let uploaded: String
                if let assetId { uploaded = assetId }
                else { uploaded = try await client.upload(video: video); assetId = uploaded }
                try await client.complete(id: room.id, assetId: uploaded, linesRecorded: linesRecorded)
                completed = true
            } catch { issue = error.localizedDescription }
        }
    }
}
