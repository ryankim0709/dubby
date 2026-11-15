import SwiftUI

/// Co-dub invites waiting on you, then conversations.
struct InboxView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                if !model.invites.isEmpty {
                    Section {
                        ForEach(model.invites) { invite in
                            InviteRow(invite: invite)
                        }
                    } header: {
                        sectionHeader("Your turn")
                    }
                }
                Section {
                    ForEach(model.conversations) { conversation in
                        NavigationLink(value: conversation) {
                            ConversationRow(conversation: conversation)
                        }
                    }
                } header: {
                    sectionHeader("Messages")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Inbox")
            .navigationDestination(for: Conversation.self) { conversation in
                ConversationView(conversation: conversation)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .dubFont(22, weight: .bold)
            .foregroundStyle(Palette.textPrimary)
    }
}

/// A friend dubbed one role and is waiting for you to take the other.
private struct InviteRow: View {
    let invite: CoDubInvite
    @Environment(AppModel.self) private var model

    private var theirs: String { invite.scene.character(id: invite.theirCharacterID)?.name ?? "" }
    private var yours: String { invite.scene.character(id: invite.yourCharacterID)?.name ?? "" }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ArtworkView(artwork: invite.scene.artwork)
                .frame(width: 72, height: 108)
                .overlay(alignment: .bottomTrailing) {
                    AvatarView(friend: invite.from, size: 28)
                        .overlay(Circle().stroke(Palette.background, lineWidth: 2))
                        .padding(6)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text("\(invite.from.name) dubbed \(theirs)")
                    .dubFont(16, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
                Text("\(invite.scene.title) · you're \(yours), \(invite.scene.lines(for: invite.yourCharacterID).count) lines")
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
                HStack(spacing: 8) {
                    Button("Accept") { model.accept(invite) }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Decline") { model.decline(invite) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Palette.hairline)
    }
}

private struct ConversationRow: View {
    let conversation: Conversation

    private var preview: String {
        guard let last = conversation.messages.last else { return "" }
        switch last.content {
        case .text(let text):
            return last.sender == .me ? "You: \(text)" : text
        case .invite(let invite):
            return last.sender == .me ? "You sent a co-dub invite" : "Co-dub invite · \(invite.scene.title)"
        }
    }

    var body: some View {
        let isUnread = conversation.unreadCount > 0
        HStack(spacing: 12) {
            AvatarView(friend: conversation.friend, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.friend.name)
                    .dubFont(16, weight: isUnread ? .bold : .medium)
                    .foregroundStyle(Palette.textPrimary)
                Text(preview)
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(isUnread ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(conversation.lastActivity)
                    .dubFont(12, weight: .regular)
                    .foregroundStyle(isUnread ? Palette.accent : Palette.textSecondary)
                if isUnread {
                    Text("\(conversation.unreadCount)")
                        .dubFont(12, weight: .bold)
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Palette.accent, in: Capsule())
                }
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Palette.hairline)
    }
}

struct ConversationView: View {
    let conversation: Conversation
    @State private var draft = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(conversation.messages) { message in
                    MessageBubble(message: message)
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.bottom)
        .screenBackground()
        .navigationTitle(conversation.friend.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                TextField("", text: $draft, prompt: Text("Message").foregroundStyle(Palette.placeholder))
                    .dubFont(16, weight: .regular)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(Palette.surface, in: Capsule())
                Button {} label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Palette.onAccent)
                        .frame(width: 44, height: 44)
                        .background(Palette.accent, in: Circle())
                }
                .disabled(draft.isEmpty)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Palette.background)
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    @Environment(AppModel.self) private var model

    private var isMine: Bool { message.sender == .me }

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 56) }
            switch message.content {
            case .text(let text):
                Text(text)
                    .dubFont(16, weight: .regular)
                    .foregroundStyle(isMine ? Palette.onAccent : Palette.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isMine ? Palette.accent : Palette.surface, in: RoundedRectangle(cornerRadius: 18))
            case .invite(let invite):
                VStack(alignment: .leading, spacing: 0) {
                    ArtworkView(artwork: invite.scene.artwork)
                        .aspectRatio(16 / 9, contentMode: .fit)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(invite.scene.title)
                            .dubFont(16, weight: .semibold)
                            .foregroundStyle(Palette.textPrimary)
                        Text("\(invite.from.name) is \(invite.scene.character(id: invite.theirCharacterID)?.name ?? ""). You're \(invite.scene.character(id: invite.yourCharacterID)?.name ?? "").")
                            .dubFont(14, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                        if !isMine && model.invites.contains(invite) {
                            Button("Accept and dub") { model.accept(invite) }
                                .buttonStyle(PrimaryButtonStyle())
                        }
                    }
                    .padding(12)
                }
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            }
            if !isMine { Spacer(minLength: 56) }
        }
    }
}
