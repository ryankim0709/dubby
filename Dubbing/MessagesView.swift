import SwiftUI

struct MessagesView: View {
    let account: AccountModel
    var body: some View {
        ClubsView(account: account)
    }
}
