import Testing
@testable import Dubbing

struct DubbingTests {
    @Test @MainActor func contentViewBuilds() {
        _ = ContentView().body
    }
}
