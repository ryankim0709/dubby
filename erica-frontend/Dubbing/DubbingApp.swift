import AVFoundation
import SwiftUI

@main
struct DubbingApp: App {
    init() {
        DisplayFont.register()
        // The app plays no sound, so its silent videos must not pause the user's music; the
        // studio switches to play-and-record while it's open so it can use the mic.
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient)
        } catch {
            assertionFailure("Couldn't set the ambient audio category: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
