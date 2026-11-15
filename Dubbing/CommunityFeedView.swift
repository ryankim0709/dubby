import SwiftUI

struct CommunityFeedView: View {
    let onCreate: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "play.rectangle.on.rectangle")
                        .dubFont(48, weight: .light)
                        .foregroundStyle(Palette.textSecondary)
                    Text("Your next scene starts here")
                        .dubFont(26, weight: .bold)
                        .multilineTextAlignment(.center)
                    Text("The community feed is on its way. Until then, make a dub and share it with your friends.")
                        .dubFont(17, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Create a dub", action: onCreate)
                        .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
                        .accessibilityIdentifier("feedCreateDub")
                }
                .padding(.vertical, 60)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .foregroundStyle(Palette.textPrimary)
            .background(.black)
            .navigationTitle("Feed")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
