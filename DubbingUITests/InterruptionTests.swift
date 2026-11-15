import XCTest

@MainActor
final class InterruptionTests: DubbingUITestCase {
    private func openStudioWithMicrophoneGranted() {
        launchWithCleanPermissions()
        _ = requireElement("discoverScreen", timeout: 30)
        openStudioForDemoScene()
    }

    func testCancelMidRecordingKeepsThePreviouslyKeptTake() {
        openStudioWithMicrophoneGranted()
        recordCurrentLineAndKeep()
        let kept = keptCount().kept
        XCTAssertEqual(kept, 1)

        tap("retryTake")
        answerSystemAlert(.microphone, allow: true, timeout: 2)
        _ = requireElement("recordingIndicator", timeout: 20)
        tap("cancelRecording")
        waitForDisappearance("recordingIndicator", timeout: 10)
        waitForValue("studioStatus", "idle", timeout: 10)

        XCTAssertEqual(keptCount().kept, kept, "Cancelling a retry must keep the take that was already kept")
        _ = requireElement("lineKept-\(value(of: "currentLine") ?? "")")
        tap("playTake")
        waitForValue("studioStatus", "playingTake", timeout: 10)
        capture("kept-take-still-plays")
    }

    func testBackgroundingDuringRecordingDiscardsTheInterruptedTake() {
        openStudioWithMicrophoneGranted()
        tap("recordLine")
        answerSystemAlert(.microphone, allow: true, timeout: 4)
        _ = requireElement("recordingIndicator", timeout: 20)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        waitForValue("studioStatus", "interrupted", timeout: 15)
        _ = requireElement("studioError")
        XCTAssertEqual(value(of: "studioError"), "recordingInterrupted")
        XCTAssertEqual(keptCount().kept, 0, "An interrupted recording must not be kept")
        capture("recording-interrupted")

        tap("recordLine")
        _ = requireElement("recordingIndicator", timeout: 20)
    }

    func testExportCancelLeavesNoSavedDub() {
        openStudioWithMicrophoneGranted()
        recordCurrentLineAndKeep()
        tap("finishDub")
        _ = requireElement("exportScreen")
        tap("cancelExport", timeout: 20)
        waitForValue("exportStatus", "cancelled", timeout: 30)
        capture("export-cancelled")
        _ = requireElement("retryExport")

        tap("exportBack")
        tap("tab-myDubs")
        _ = requireElement("myDubsEmpty")
    }

    func testBackgroundingDuringExportEndsInAnExplicitState() {
        openStudioWithMicrophoneGranted()
        recordCurrentLineAndKeep()
        tap("finishDub")
        _ = requireElement("exportScreen")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let terminal = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 'finished' OR value == 'failed' OR value == 'cancelled'"),
            object: element("exportStatus")
        )
        XCTAssertEqual(XCTWaiter().wait(for: [terminal], timeout: 240), .completed, "Export must end in finished, failed, or cancelled after backgrounding; last value: \(value(of: "exportStatus") ?? "nil")")
        capture("export-after-background")
        if value(of: "exportStatus") == "failed" {
            _ = requireElement("exportError")
            _ = requireElement("retryExport")
        }
    }
}
