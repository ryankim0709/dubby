import XCTest

final class DubbingUITests: XCTestCase {
    @MainActor
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["-DUBBY_UI_TEST", "1"]
        app.launch()
        XCTAssertTrue(app.buttons["createDub"].waitForExistence(timeout: 10))
    }
}
