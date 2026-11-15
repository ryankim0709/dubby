import SwiftUI

enum InboxSection: String, CaseIterable, Identifiable {
    case clubs = "Clubs"
    case coDubs = "Co-dubs"

    var id: Self { self }
}

struct MessagesView: View {
    let account: AccountModel
    let scoring: DubScoringModel?
    @Binding var section: InboxSection
    let state: LoadState<SocialSnapshot>
    let onAccount: () -> Void
    let onRetry: () -> Void
    let onFriends: () -> Void
    let onOpenRoom: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inbox", selection: $section) {
                ForEach(InboxSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            switch section {
            case .clubs: ClubsView(account: account, scoring: scoring)
            case .coDubs:
                CoDubInboxView(account: account, state: state, onAccount: onAccount, onRetry: onRetry, onFriends: onFriends, onOpenRoom: onOpenRoom)
            }
        }
        .screenBackground()
    }
}

private struct CoDubInboxView: View {
    let account: AccountModel
    let state: LoadState<SocialSnapshot>
    let onAccount: () -> Void
    let onRetry: () -> Void
    let onFriends: () -> Void
    let onOpenRoom: (String) -> Void
    @State private var inviteCode = ""
    @State private var isJoining = false
    @State private var issue: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SocialContent(account: account, state: state, onAccount: onAccount, onRetry: onRetry) { snapshot in
                    if !snapshot.requests.filter(\.incoming).isEmpty {
                        Button("You have \(snapshot.requests.filter(\.incoming).count) friend requests", systemImage: "person.badge.plus", action: onFriends)
                            .frame(minHeight: 44).accessibilityIdentifier("incomingFriendRequests")
                    }
                    DisclosureGroup("Have an invitation link?") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Paste a link or invite code", text: $inviteCode)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("coDubInviteCode")
                            Button(isJoining ? "Opening invitation…" : "Open invitation", action: join)
                                .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control)).disabled(isJoining || inviteCode.isEmpty)
                                .accessibilityIdentifier("redeemCoDubInvite")
                        }.padding(.top, 12)
                    }
                    if snapshot.rooms.isEmpty {
                        EmptyStateView(systemImage: "tray", title: "Who's your next co-star?", message: "Finish your character's lines, then invite a friend from the result screen. Your invitations and combined dubs appear here.")
                    }
                    ForEach(snapshot.rooms) { room in
                        Button { onOpenRoom(room.id) } label: {
                            AdaptiveStack(rowAlignment: .center, spacing: 12) {
                                let partner = room.owner.id == snapshot.me.id ? room.guest?.username ?? "Open invitation" : room.owner.username
                                SocialAvatar(username: partner)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(room.script.title).dubFont(20, weight: .semibold)
                                    Text("\(partner) · \(room.status.title)").dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary)
                                    Text("\(room.script.roleName(room.script.ownerCharacterId)) + \(room.script.roleName(room.script.guestCharacterId))").dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").foregroundStyle(Palette.textSecondary)
                            }.frame(minHeight: 72)
                        }.buttonStyle(.plain).accessibilityIdentifier("coDub-\(room.id)")
                        Divider().overlay(Palette.hairline)
                    }
                }
                if let issue { Text(issue).dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary).accessibilityIdentifier("joinCoDubError") }
            }.padding(20)
        }
        .screenBackground().foregroundStyle(Palette.textPrimary)
        .navigationTitle("Inbox").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Friends", systemImage: "person.2", action: onFriends).labelStyle(.iconOnly) } }
    }

    private func join() {
        isJoining = true
        issue = nil
        Task {
            defer { isJoining = false }
            do {
                let code = try CoDubLink.code(from: inviteCode)
                let id = try await SocialBackendClient.configured(account: account).redeem(code: code)
                inviteCode = ""
                onOpenRoom(id)
            } catch { issue = error.localizedDescription }
        }
    }
}
