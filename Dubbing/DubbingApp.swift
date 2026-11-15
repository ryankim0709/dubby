import SwiftUI

@main
struct DubbingApp: App {
    @State private var account = AccountModel.live(in: .main)
    @State private var pendingCoDubCode: String?
    @State private var linkIssue: String?

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
                    ContentView(account: account, pendingCoDubCode: $pendingCoDubCode)
                }
            }
            .task {
                await account.start()
            }
            .onOpenURL { url in
                do { pendingCoDubCode = try CoDubLink.code(from: url.absoluteString) }
                catch { linkIssue = error.localizedDescription }
            }
            .alert("Couldn't open invitation", isPresented: Binding(get: { linkIssue != nil }, set: { if !$0 { linkIssue = nil } })) {
                Button("OK") { linkIssue = nil }
            } message: { Text(linkIssue ?? "") }
        }
    }
}
