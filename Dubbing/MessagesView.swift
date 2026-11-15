import SwiftUI

struct MessagesView: View {
    let account: AccountModel
    let scoring: DubScoringModel?
    var body: some View {
        ClubsView(account: account, scoring: scoring)
    }
}
