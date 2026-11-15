import SwiftUI

/// DMs need accounts and a backend, which aren't set up yet, so this says so instead of showing sample chats.
struct MessagesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Messages")
                    .dubFont(24, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.top, 8)
                EmptyStateView(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "Dubbing with friends is coming",
                    message: "Sending scenes to friends needs accounts, which aren't set up yet. For now, share finished dubs from My Dubs."
                )
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .background(Palette.background)
        .toolbar(.hidden, for: .navigationBar)
    }
}
