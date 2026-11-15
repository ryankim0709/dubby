import SwiftUI

@main
struct DubbingApp: App {
    @State private var account: AccountModel
    /// Nil when the build has no backend, so finished dubs aren't scored.
    @State private var scoring: DubScoringModel?

    init() {
        DisplayFont.register()
        LaunchConfiguration.current.prepareProcess()
        let account = AccountModel.live(in: .main)
        _account = State(initialValue: account)
        _scoring = State(initialValue: account.convexClient.map { DubScoringModel(client: $0) })
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // A build without a backend can't sign anyone in, so it opens the app signed out.
                if account.isAvailable && !account.phase.isSignedIn {
                    SignInView(account: account)
                } else {
                    ContentView(account: account, scoring: scoring)
                }
            }
            .task {
                await account.start()
            }
        }
    }
}
