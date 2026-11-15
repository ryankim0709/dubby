import AVFoundation
import Foundation
import Testing
@testable import Dubbing

/// The take lifecycle as a value: retries never lose a kept take until a new one is kept.
struct TakeBookTests {
    private func take(_ name: String) -> RecordedTake {
        RecordedTake(url: URL(filePath: "/\(name).m4a"), duration: 1, inputSource: .microphone)
    }

    @Test func keptTakeSurvivesCancelledFailedAndDiscardedRetries() {
        var book = TakeBook()
        #expect(book.begin(lineID: 3, url: take("first").url))
        #expect(book.finish(take("first")) == nil)
        #expect(book.kept[3] == nil, "a finished take is only a candidate")
        #expect(book.keepCandidate(lineID: 3))
        #expect(book.kept[3] == take("first"))

        // A retry that is cancelled, fails or is interrupted ends the same way: its file is handed back for deletion.
        #expect(book.begin(lineID: 3, url: take("cancelled").url))
        #expect(book.abandon() == take("cancelled").url)
        #expect(book.kept[3] == take("first"))
        #expect(book.inFlight == nil)

        // A finished retry waits as a candidate; discarding it keeps the earlier take.
        #expect(book.begin(lineID: 3, url: take("second").url))
        _ = book.finish(take("second"))
        #expect(book.latestTake(lineID: 3) == take("second"))
        #expect(book.discardCandidate(lineID: 3) == take("second").url)
        #expect(book.kept[3] == take("first"))

        // Another finished retry replaces an older candidate, and keeping it replaces the kept take.
        _ = book.begin(lineID: 3, url: take("third").url)
        _ = book.finish(take("third"))
        _ = book.begin(lineID: 3, url: take("fourth").url)
        #expect(book.finish(take("fourth")) == take("third").url)
        #expect(book.keepCandidate(lineID: 3))
        #expect(book.kept[3] == take("fourth"))
        #expect(book.candidates.isEmpty)
    }

    @Test func onlyOneRecordingAtATimeAndOnlyTheOneInFlightFinishes() {
        var book = TakeBook()
        #expect(book.begin(lineID: 1, url: take("a").url))
        #expect(!book.begin(lineID: 2, url: take("b").url))
        #expect(book.finish(take("b")) == nil)
        #expect(book.candidates.isEmpty)
        #expect(!book.keepCandidate(lineID: 2))
    }
}

struct StudioInterruptionTests {
    @Test func mapsSystemNotificationsToTypedInterruptions() {
        let began: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        let ended: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        #expect(StudioInterruption(interruptionUserInfo: began) == .audioSessionInterrupted)
        #expect(StudioInterruption(interruptionUserInfo: ended) == nil)
        #expect(StudioInterruption(interruptionUserInfo: [:]) == nil)

        let unplugged: [AnyHashable: Any] = [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        let pluggedIn: [AnyHashable: Any] = [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue]
        #expect(StudioInterruption(routeChangeUserInfo: unplugged) == .audioRouteLost)
        #expect(StudioInterruption(routeChangeUserInfo: pluggedIn) == nil)
    }

    @Test func readsTheFixtureLaunchArgument() {
        #expect(TakeInputSource.parse(arguments: ["Dubbing", "-DUBIT_AUDIO_FIXTURE", "qa-speech-fixture"]) == .fixture(name: "qa-speech-fixture"))
        #expect(TakeInputSource.parse(arguments: ["Dubbing", "-DUBIT_AUDIO_FIXTURE"]) == .microphone)
        #expect(TakeInputSource.parse(arguments: ["Dubbing"]) == .microphone)
        #expect(TakeInputSource.fixture(name: "x").isSynthetic)
        #expect(!TakeInputSource.microphone.isSynthetic)
    }
}

/// The take session on the SYNTHETIC scene, recording from a synthetic fixture so no microphone is involved.
/// Permission and the audio session are injected; everything else (player, recorder, files) is real.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct TakeSessionTests {
    private let fixtureHz = SyntheticScene.takeHz

    private func makeSession(_ name: String, permission: MicrophonePermission) async throws -> (TakeSession, ScriptLine) {
        let folder = scratchFolder(name)
        let scene = try await CuratedSceneLoader.loadScene(manifestURL: try await SyntheticScene.make(in: folder))
        let setup = try await CuratedSceneStudio.makeSetup(scene: scene, characterID: "alice", barCount: 8, workingDirectory: folder.appending(path: "work"))
        let fixture = folder.appending(path: "synthetic-fixture.m4a")
        try ToneAudio.writeAAC(
            ToneAudio.tone(fixtureHz, amplitude: 0.2, seconds: 4, sampleRate: SyntheticScene.sampleRate),
            sampleRate: SyntheticScene.sampleRate,
            to: fixture
        )
        let session = TakeSession(
            setup: setup,
            player: SegmentPlayer(url: setup.clip.url),
            recorder: TakeRecorder(fixtureNamed: "synthetic-fixture", url: fixture),
            permission: permission,
            audio: StudioAudioControl(activate: {}, deactivate: {})
        )
        let line = try #require(setup.script.lines(spokenBy: setup.characterID).first)
        return (session, line)
    }

    private static let granted = MicrophonePermission { true }
    private static let denied = MicrophonePermission { false }

    /// Starts a recording and waits until audio is being captured.
    private func startRecording(_ session: TakeSession, _ line: ScriptLine) async throws -> Task<Void, Never> {
        let task = Task { await session.record(line) }
        var waited = 0
        while session.activity != .recording(lineID: line.id), waited < 400 {
            try await Task.sleep(for: .milliseconds(25))
            waited += 1
        }
        #expect(session.activity == .recording(lineID: line.id))
        try await Task.sleep(for: .milliseconds(300))
        return task
    }

    private func takeFiles(_ session: TakeSession) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: session.setup.clip.workingDirectory.path(percentEncoded: false)).sorted()
    }

    @Test func recordsAFixtureTakeAcrossTheRecordingWindowAsACandidate() async throws {
        let (session, line) = try await makeSession("TakeSessionRecord", permission: Self.granted)
        let window = session.setup.timing(for: line).recordingWindow
        await session.record(line)
        #expect(session.lastOutcome == .candidate(lineID: line.id))
        #expect(session.activity == .idle)
        let candidate = try #require(session.book.candidates[line.id])
        #expect(candidate.inputSource == .fixture(name: "synthetic-fixture"))
        #expect(abs(candidate.duration - (window.end - window.start)) < 0.3, "take lasts \(candidate.duration) s")
        #expect(session.book.kept.isEmpty)

        let audio = try MediaPipeline.readMonoAudio(from: candidate.url)
        let steady = ToneAudio.window(audio.samples, TimeSpan(start: 0.2, end: 0.7), sampleRate: audio.sampleRate)
        #expect(ToneAudio.power(steady, at: fixtureHz, sampleRate: audio.sampleRate) > 0.0025, "the fixture's tone is in the take")

        session.keepCandidate(lineID: line.id)
        #expect(session.keptTakes[line.id] == candidate)
        session.close()
    }

    @Test func cancelAndInterruptionNeverReplaceTheKeptTake() async throws {
        let (session, line) = try await makeSession("TakeSessionCancel", permission: Self.granted)
        await session.record(line)
        session.keepCandidate(lineID: line.id)
        let kept = try #require(session.keptTakes[line.id])

        let cancelled = try await startRecording(session, line)
        session.cancelRecording()
        await cancelled.value
        #expect(session.lastOutcome == .cancelled(lineID: line.id))
        #expect(session.keptTakes[line.id] == kept)
        #expect(session.book.candidates.isEmpty)
        #expect(try takeFiles(session) == [kept.url.lastPathComponent], "the cancelled take's file is deleted")

        let interrupted = try await startRecording(session, line)
        session.interrupt(.audioRouteLost)
        await interrupted.value
        #expect(session.lastOutcome == .interrupted(lineID: line.id, .audioRouteLost))
        #expect(session.keptTakes[line.id] == kept)
        #expect(try takeFiles(session) == [kept.url.lastPathComponent])

        let cancelledTask = try await startRecording(session, line)
        cancelledTask.cancel()
        await cancelledTask.value
        #expect(session.lastOutcome == .cancelled(lineID: line.id))
        #expect(session.keptTakes[line.id] == kept)

        // Stopping early keeps what was recorded, as a candidate beside the kept take.
        let stopped = try await startRecording(session, line)
        session.stopRecording()
        await stopped.value
        #expect(session.lastOutcome == .candidate(lineID: line.id))
        #expect(session.keptTakes[line.id] == kept)
        session.discardCandidate(lineID: line.id)
        #expect(try takeFiles(session) == [kept.url.lastPathComponent])
        session.close()
    }

    @Test func microphoneDenialFailsWithFixtureInputToo() async throws {
        let (session, line) = try await makeSession("TakeSessionDenied", permission: Self.denied)
        await session.record(line)
        #expect(session.lastOutcome == .failed(lineID: line.id, error: .microphoneDenied))
        #expect(session.book.inFlight == nil)
        #expect(session.book.candidates.isEmpty)
        #expect(session.activity == .idle)
        session.close()
    }
}
