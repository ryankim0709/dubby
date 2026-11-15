import SwiftUI

@main
struct DubbingApp: App {
    @State private var account = AccountModel.live(in: .main)

    init() {
        LaunchConfiguration.current.prepareProcess()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(account: account)
        }
    }
}
