import SwiftUI

@main
struct DubbingApp: App {
    @State private var account = AccountModel.live(in: .main)

    init() {
        DisplayFont.register()
        LaunchConfiguration.current.prepareProcess()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // A build without a backend can't sign anyone in, so it opens the app signed out.
                if account.isAvailable && !account.phase.isSignedIn {
                    SignInView(account: account)
                } else {
                    ContentView(account: account)
                }
            }
            .task {
                await account.start()
            }
        }
    }
}
