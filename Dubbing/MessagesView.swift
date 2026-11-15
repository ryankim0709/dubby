import SwiftUI

/// Invitations and conversations stay empty until the messaging service is connected.
struct MessagesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Inbox")
                    .dubFont(32, weight: .bold)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.top, 8)
                EmptyStateView(
                    systemImage: "tray",
                    title: "A little quiet in here",
                    message: "Co-dub invitations and conversations are on their way. You can already share your finished dubs from Shelf."
                )
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
    }
}
