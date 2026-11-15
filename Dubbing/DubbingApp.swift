import SwiftUI

@main
struct DubbingApp: App {
    init() {
        LaunchConfiguration.current.prepareProcess()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
