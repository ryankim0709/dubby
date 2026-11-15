import XCTest

@MainActor
final class PermissionTests: DubbingUITestCase {
    func testMicrophoneDeniedShowsRecoveryAndRecordsAfterGrantInSettings() {
        launchWithCleanPermissions()
        _ = requireElement("discoverScreen", timeout: 30)
        openStudioForDemoScene()

        tap("recordLine")
        XCTAssertTrue(answerSystemAlert(.microphone, allow: false), "The microphone prompt did not appear after the first record tap")
        _ = requireElement("microphonePermissionBanner")
        XCTAssertEqual(value(of: "microphonePermissionBanner"), "denied")
        XCTAssertFalse(element("recordingIndicator").exists, "Recording must not start without microphone access")
        XCTAssertEqual(keptCount().kept, 0, "A denied microphone must not produce a take")
        capture("microphone-denied")

        tap("openSettings")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15), "The Settings app did not open")
        let microphoneSwitch = settings.switches["Microphone"]
        XCTAssertTrue(microphoneSwitch.waitForExistence(timeout: 10), "The app's Settings page has no Microphone switch")
        XCTAssertEqual(microphoneSwitch.value as? String, "0")
        microphoneSwitch.tap()
        XCTAssertEqual(microphoneSwitch.value as? String, "1")
        capture("settings-microphone-on")

        app.activate()
        tap("permissionRetry")
        _ = requireElement("recordingIndicator", timeout: 20)
        waitForDisappearance("recordingIndicator", timeout: 60)
        tap("keepTake")
        XCTAssertEqual(keptCount().kept, 1)
        XCTAssertFalse(element("microphonePermissionBanner").exists, "The denied banner must clear after recovery")
        capture("recovered")
    }

    func testSpeechRecognitionDeniedShowsRecoverableState() {
        launchWithCleanPermissions()
        _ = requireElement("discoverScreen", timeout: 30)
        tap("dubScene-\(DemoScene.sceneID)")
        guard element("transcribeScene").waitForExistence(timeout: 5) else {
            XCTFail("This build does not request speech recognition at scene setup; see docs/qa/smoke-flow.md step S-20 for where it moved")
            return
        }
        tap("transcribeScene")
        XCTAssertTrue(answerSystemAlert(.speechRecognition, allow: false), "The speech recognition prompt did not appear")
        _ = requireElement("speechPermissionNotice")
        XCTAssertEqual(value(of: "speechPermissionNotice"), "denied")
        XCTAssertFalse(element("scriptScreen").exists, "A denied speech permission must not produce a script")
        capture("speech-denied")
    }
}
