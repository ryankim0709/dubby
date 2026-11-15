import AVFoundation
import Foundation
import Testing
@testable import Dubbing

struct TakeMeasurementTests {
    private func measurement(take: Double, allowed: Double, peak: Double?) -> TakeMeasurement {
        TakeMeasurement(lineID: 0, takeSeconds: take, lineSeconds: 2, allowedSeconds: allowed, peakDecibels: peak)
    }

    @Test func judgesLevelFromThePeakAndLeavesItUnknownWithoutAudio() {
        #expect(measurement(take: 1, allowed: 2, peak: -80).level == .silent)
        #expect(measurement(take: 1, allowed: 2, peak: -35).level == .quiet)
        #expect(measurement(take: 1, allowed: 2, peak: -6).level == .clear)
        #expect(measurement(take: 1, allowed: 2, peak: nil).level == nil)
    }

    @Test func reportsOnlyOverrunsLongEnoughToNotice() {
        #expect(measurement(take: 2.1, allowed: 2.75, peak: -6).fitsLine)
        #expect(measurement(take: 2.8, allowed: 2.75, peak: -6).fitsLine)
        let overrun = measurement(take: 3.5, allowed: 2.75, peak: -6)
        #expect(!overrun.fitsLine)
        #expect(abs((overrun.overrunSeconds ?? 0) - 0.75) < 1e-9)
    }

    @Test func measuresARealRecordingsLevelAndFlagsUnreadableAudio() async throws {
        let line = ScriptLine(id: 3, text: "Hello there", start: 1, end: 3, speakerID: 0, envelope: [])
        let folder = FileManager.default.temporaryDirectory.appending(path: "TakeMeasurementTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let tone = (0..<44_100).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 44_100)) }
        let spoken = try writeAudio(tone, to: folder.appending(path: "tone.caf"))
        let heard = await TakeMeasuring.measure(take: RecordedTake(url: spoken, duration: 1), line: line, lines: [line], sectionDuration: 10)
        #expect(heard.level == .clear)
        #expect(heard.lineID == 3)
        #expect(heard.takeSeconds == 1)
        #expect(heard.lineSeconds == 2)
        #expect(abs(heard.allowedSeconds - 2.75) < 1e-9)

        let quiet = try writeAudio([Float](repeating: 0, count: 44_100), to: folder.appending(path: "silence.caf"))
        let nothing = await TakeMeasuring.measure(take: RecordedTake(url: quiet, duration: 1), line: line, lines: [line], sectionDuration: 10)
        #expect(nothing.level == .silent)

        let missing = await TakeMeasuring.measure(take: RecordedTake(url: folder.appending(path: "missing.caf"), duration: 1), line: line, lines: [line], sectionDuration: 10)
        #expect(missing.peakDecibels == nil)
        #expect(missing.level == nil)
    }

    private func writeAudio(_ samples: [Float], to url: URL) throws -> URL {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try #require(buffer.floatChannelData?[0])
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }
}

struct SavedDubHistoryTests {
    private func makeFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "SavedDubHistoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func makeVideo() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }

    private func dub(_ title: String, measurements: [TakeMeasurement]?) -> SavedDub {
        let id = UUID()
        return SavedDub(
            id: id,
            sceneTitle: title,
            characterName: "Speaker 1",
            linesDubbed: 1,
            totalLines: 2,
            sceneSeconds: 8,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            videoFileName: "\(id.uuidString).mp4",
            takeMeasurements: measurements
        )
    }

    private let measured = TakeMeasurement(lineID: 0, takeSeconds: 1.5, lineSeconds: 2, allowedSeconds: 2.75, peakDecibels: -8)

    @Test func measuredDubReloadsFromDiskWithItsMeasurements() throws {
        let folder = makeFolder()
        let saved = dub("Measured", measurements: [measured])
        _ = try DubLibrary.save(video: try makeVideo(), as: saved, in: folder)

        // A fresh load reads only the files, as a relaunched app does.
        let reloaded = try DubLibrary.load(from: folder)
        #expect(reloaded == [saved])
        #expect(reloaded.first?.takeMeasurements == [measured])
    }

    @Test func dubsSavedBeforeMeasurementStillLoadAndStayUnmeasured() throws {
        let folder = makeFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","sceneTitle":"Old","characterName":"Speaker 1","linesDubbed":1,"totalLines":2,"sceneSeconds":8,"createdAt":"2026-11-14T10:00:00Z","videoFileName":"old.mp4"}]
        """
        try Data(json.utf8).write(to: folder.appending(path: "dubs.json"))

        let reloaded = try DubLibrary.load(from: folder)
        #expect(reloaded.count == 1)
        #expect(reloaded[0].takeMeasurements == nil)
        let practice = MeasuredPractice(dubs: reloaded)
        #expect(!practice.hasMeasurements)
        #expect(practice.dubsWithoutMeasurements == 1)
    }

    @Test func deletingRemovesTheEntryAndItsVideo() throws {
        let folder = makeFolder()
        let keep = dub("Keep", measurements: nil)
        let drop = dub("Drop", measurements: nil)
        _ = try DubLibrary.save(video: try makeVideo(), as: keep, in: folder)
        _ = try DubLibrary.save(video: try makeVideo(), as: drop, in: folder)

        let remaining = try DubLibrary.delete(drop, in: folder)
        #expect(remaining.map(\.sceneTitle) == ["Keep"])
        #expect(try DubLibrary.load(from: folder).map(\.sceneTitle) == ["Keep"])
        #expect(!FileManager.default.fileExists(atPath: DubLibrary.videoURL(for: drop, in: folder).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: DubLibrary.videoURL(for: keep, in: folder).path(percentEncoded: false)))
    }
}

struct MeasuredPracticeTests {
    private func take(_ seconds: Double, allowed: Double, peak: Double?) -> TakeMeasurement {
        TakeMeasurement(lineID: 0, takeSeconds: seconds, lineSeconds: 2, allowedSeconds: allowed, peakDecibels: peak)
    }

    @Test func showsNothingMeasuredWithoutRecordings() {
        let practice = MeasuredPractice(measurements: [])
        #expect(!practice.hasMeasurements)
        #expect(practice.measuredTakes == 0)
        #expect(practice.takesFittingLine == 0)
    }

    @Test func countsOnlyWhatWasMeasured() {
        let practice = MeasuredPractice(measurements: [
            take(1.5, allowed: 2.75, peak: -8),
            take(4, allowed: 2.75, peak: -30),
            take(1, allowed: 2.75, peak: -90),
            take(1, allowed: 2.75, peak: nil),
        ])
        #expect(practice.measuredTakes == 4)
        #expect(practice.takesFittingLine == 3)
        #expect(practice.takesWithVoice == 2)
        #expect(practice.silentTakes == 1)
    }
}

struct PermissionStateTests {
    @Test func microphoneAccessFollowsTheSystemPermission() {
        #expect(MicrophoneAccess(.denied) == .denied)
        #expect(MicrophoneAccess(.granted) == .granted)
        #expect(MicrophoneAccess(.undetermined) == .undetermined)
    }

    @Test func onlyPermissionDenialsPointToSettings() {
        #expect(FlowIssue(error: DubFlowError.microphoneDenied).opensSettings)
        #expect(FlowIssue(error: DubFlowError.speechRecognitionDenied).opensSettings)
        #expect(!FlowIssue(error: DubFlowError.noSpeechFound).opensSettings)
        #expect(!FlowIssue(error: DubFlowError.recordingFailed("take.m4a")).opensSettings)
        #expect(FlowIssue(error: DubFlowError.noSpeechFound).message == DubFlowError.noSpeechFound.errorDescription)
    }
}

struct LaunchConfigurationTests {
    private func clip(_ name: String) -> LibraryClip {
        LibraryClip(url: URL(filePath: "/bundle/\(name).mp4"), title: name, durationSeconds: 10)
    }

    @Test func readsOnlyTheDocumentedArguments() {
        let configuration = LaunchConfiguration(arguments: [
            "Dubbing", "-DUBIT_UI_TEST", "1", "-DUBIT_DEMO_SCENE", "demo", "-DUBIT_EXPORT_STEP_DELAY_MS", "250", "-Other", "x",
        ])
        #expect(configuration.isUITest)
        #expect(configuration.demoSceneID == "demo")
        #expect(configuration.exportStepDelayMilliseconds == 250)
    }

    @Test func ignoresMissingOrInvalidValues() {
        let configuration = LaunchConfiguration(arguments: ["-DUBIT_UI_TEST", "0", "-DUBIT_EXPORT_STEP_DELAY_MS", "soon", "-DUBIT_DEMO_SCENE"])
        #expect(!configuration.isUITest)
        #expect(configuration.demoSceneID == nil)
        #expect(configuration.exportStepDelayMilliseconds == nil)
        #expect(LaunchConfiguration.inactive == LaunchConfiguration(arguments: []))
    }

    @Test func listsTheDemoSceneFirstAndLeavesOtherOrderAlone() {
        let clips = [clip("alpha"), clip("demo"), clip("omega")]
        let ordered = LaunchConfiguration(arguments: ["-DUBIT_DEMO_SCENE", "demo"]).ordering(clips)
        #expect(ordered.map(\.sceneID) == ["demo", "alpha", "omega"])
        #expect(LaunchConfiguration(arguments: ["-DUBIT_DEMO_SCENE", "missing"]).ordering(clips) == clips)
        #expect(LaunchConfiguration.inactive.ordering(clips) == clips)
    }

    @Test func cleanStateRemovesFoldersAndToleratesMissingOnes() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "CleanStateTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appending(path: "dubs.json"))
        CleanState.wipe(folders: [folder, folder.appending(path: "missing")])
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }
}

struct IssueStateTests {
    @Test func exposesTheErrorCaseWithoutItsPayload() {
        #expect(FlowIssue(error: DubFlowError.recordingInterrupted("a call came in")).code == "recordingInterrupted")
        #expect(FlowIssue(error: DubFlowError.recordingFailed("take.m4a")).code == "recordingFailed")
        #expect(FlowIssue(error: DubFlowError.microphoneDenied).code == "microphoneDenied")
    }

    @Test func aTakeWithoutAudioShowsNoLevelInsteadOfAnInventedOne() {
        let unread = TakeMeasurement(lineID: 1, takeSeconds: 1, lineSeconds: 2, allowedSeconds: 2.75, peakDecibels: nil)
        #expect(unread.levelDescription == nil)
        #expect(!MeasuredPractice(measurements: []).hasMeasurements)
    }
}
