import XCTest

@MainActor
final class SmokeFlowTests: DubbingUITestCase {
    func testDubLoopFromCleanInstallToShare() {
        launchWithCleanPermissions()
        _ = requireElement("discoverScreen", timeout: 30)
        capture("discover-clean")

        tap("tab-myDubs")
        _ = requireElement("myDubsEmpty")
        capture("my-dubs-empty")
        tap("tab-discover")

        _ = requireElement("sceneCard-\(DemoScene.sceneID)")
        openStudioForDemoScene()
        XCTAssertTrue(element("fixtureInputBadge").exists, "The synthetic-input badge must be visible while the audio fixture replaces the microphone")
        XCTAssertEqual(keptCount().kept, 0, "A clean install starts with no kept takes")

        recordAllLines()
        let progress = keptCount()
        XCTAssertEqual(progress.kept, progress.total, "Every line of the chosen character must be kept before export")

        tap("finishDub")
        _ = requireElement("exportScreen")
        capture("export-started")
        waitForValue("exportStatus", "finished", timeout: 240)
        waitForValue("resultPlayer", "ready", timeout: 30)
        capture("export-preview")

        if element("saveDub").exists {
            tap("saveDub")
        }
        waitForValue("savedStatus", "saved", timeout: 30)
        capture("saved")

        openAndCloseShareSheet(from: "shareDub")
        tap("doneDub")

        tap("tab-myDubs")
        _ = requireElement("myDubsScreen")
        waitForValue("myDubsCount", "1", timeout: 10)
        capture("my-dubs-one")

        app.terminate()
        app.launchArguments = [
            "-DUBIT_DEMO_SCENE", DemoScene.sceneID,
            "-DUBIT_AUDIO_FIXTURE", DemoScene.audioFixture,
        ]
        app.launch()
        tap("tab-myDubs")
        waitForValue("myDubsCount", "1", timeout: 10)
        let saved = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'savedDub-'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "The saved dub must survive a relaunch")
        saved.tap()
        _ = requireElement("savedDubPlayer")
        capture("saved-dub-player")
        openAndCloseShareSheet(from: "shareSavedDub")
        tap("savedDubDone")
    }
}
