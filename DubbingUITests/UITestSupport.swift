import XCTest

enum DemoScene {
    static let sceneID = "demo"
    static let audioFixture = "qa-speech-fixture"
}

enum SystemPrompt {
    case microphone
    case speechRecognition

    var allowButtons: [String] {
        switch self {
        case .microphone: ["Allow"]
        case .speechRecognition: ["OK", "Allow"]
        }
    }

    var denyButtons: [String] { ["Don\u{2019}t Allow", "Don't Allow"] }
}

@MainActor
class DubbingUITestCase: XCTestCase {
    var app: XCUIApplication!
    private var captureIndex = 0

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-DUBIT_UI_TEST", "1",
            "-DUBIT_DEMO_SCENE", DemoScene.sceneID,
            "-DUBIT_AUDIO_FIXTURE", DemoScene.audioFixture,
        ]
    }

    func launchWithCleanPermissions() {
        app.resetAuthorizationStatus(for: .microphone)
        app.launch()
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func requireElement(_ identifier: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let match = element(identifier)
        XCTAssertTrue(match.waitForExistence(timeout: timeout), "Missing accessibility identifier \"\(identifier)\" (see docs/qa/accessibility-ids.md)", file: file, line: line)
        return match
    }

    func tap(_ identifier: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let match = requireElement(identifier, timeout: timeout, file: file, line: line)
        XCTAssertTrue(match.isHittable, "\"\(identifier)\" exists but is not hittable", file: file, line: line)
        match.tap()
    }

    func value(of identifier: String) -> String? {
        element(identifier).value as? String
    }

    func waitForValue(_ identifier: String, _ expected: String, timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: element(identifier))
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "\"\(identifier)\" never reached value \"\(expected)\"; last value: \(value(of: identifier) ?? "nil")", file: file, line: line)
    }

    func waitForDisappearance(_ identifier: String, timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(identifier))
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "\"\(identifier)\" is still on screen", file: file, line: line)
    }

    func capture(_ name: String) {
        captureIndex += 1
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = String(format: "%02d-%@", captureIndex, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    func answerSystemAlert(_ prompt: SystemPrompt, allow: Bool, timeout: TimeInterval = 10) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: timeout) else { return false }
        let names = allow ? prompt.allowButtons : prompt.denyButtons
        for name in names {
            let button = alert.buttons[name]
            if button.exists {
                button.tap()
                return true
            }
        }
        XCTFail("System alert has none of the buttons \(names); buttons: \(alert.buttons.allElementsBoundByIndex.map(\.label))")
        return false
    }

    func keptCount() -> (kept: Int, total: Int) {
        let parts = (value(of: "studioProgress") ?? "").split(separator: " ")
        guard parts.count == 3, let kept = Int(parts[0]), let total = Int(parts[2]) else {
            XCTFail("studioProgress must have the value \"<kept> of <total>\"; got \(value(of: "studioProgress") ?? "nil")")
            return (0, 0)
        }
        return (kept, total)
    }
}

extension DubbingUITestCase {
    func openStudioForDemoScene() {
        tap("dubScene-\(DemoScene.sceneID)")
        if element("transcribeScene").waitForExistence(timeout: 5) {
            tap("transcribeScene")
        }
        _ = requireElement("scriptScreen", timeout: 120)
        capture("script-review")
        let characters = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'characterCard-'"))
        XCTAssertGreaterThan(characters.count, 0, "Script review must list at least one characterCard-<id>")
        characters.firstMatch.tap()
        tap("startDubbing")
        _ = requireElement("studioScreen", timeout: 20)
        capture("studio-opened")
    }

    func recordCurrentLineAndKeep() {
        tap("recordLine")
        answerSystemAlert(.microphone, allow: true, timeout: 4)
        _ = requireElement("recordingIndicator", timeout: 20)
        capture("recording")
        waitForDisappearance("recordingIndicator", timeout: 60)
        waitForValue("studioStatus", "idle", timeout: 10)
        tap("keepTake")
    }

    func openAndCloseShareSheet(from identifier: String) {
        tap(identifier)
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "The system share sheet (ActivityListView) did not appear")
        capture("share-sheet")
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "The share sheet has no Close button")
        close.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "The share sheet did not dismiss")
    }

    func recordAllLines() {
        let total = keptCount().total
        for index in 0..<total {
            let before = keptCount().kept
            tap("listenToOriginal")
            waitForValue("studioStatus", "playingOriginal", timeout: 10)
            waitForValue("studioStatus", "idle", timeout: 60)
            recordCurrentLineAndKeep()
            XCTAssertEqual(keptCount().kept, before + 1, "Keeping line \(index + 1) must raise studioProgress by one")
            capture("line-\(index + 1)-kept")
            if index < total - 1 { tap("studioNext") }
        }
    }
}
