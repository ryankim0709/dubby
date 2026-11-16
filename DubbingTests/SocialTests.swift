import AVFoundation
import Foundation
import Testing
@testable import Dubbing

struct SocialLinkTests {
    @Test func invitationLinksRoundTripAndRejectOtherSchemesOrPartialCodes() throws {
        let code = UUID().uuidString.lowercased()
        let link = try CoDubLink.url(code: code)
        #expect(try CoDubLink.code(from: link.absoluteString) == code)
        #expect(try CoDubLink.code(from: "  \(code.uppercased())  ") == code)
        #expect(throws: SocialError.self) { try CoDubLink.code(from: "https://someone.example/invite/\(code)") }
        #expect(throws: SocialError.self) { try CoDubLink.code(from: "dubby://invite/short-code") }
    }
}

struct SocialUploadTests {
    private struct SignedOut: CoachAuthTokenProvider {
        func convexAuthToken() async throws -> String? { nil }
    }

    private var client: SocialBackendClient {
        let url = URL(string: "https://example.invalid")!
        return SocialBackendClient(cloudURL: url, siteURL: url, tokens: SignedOut())
    }

    @Test(arguments: [1.0, 31.0, 121.0])
    func playableVideosReachAuthenticationRegardlessOfDuration(seconds: Double) async throws {
        let folder = try TemporaryDirectory(prefix: "SocialUploadDuration")
        let video = folder.appending(path: "synthetic.mp4")
        try await SyntheticScene.writeBlackVideo(to: video, seconds: seconds, framesPerSecond: 1)
        #expect(abs(try await MediaPipeline.loadDuration(of: video) - seconds) < 0.1)
        let error = try await #require(throws: SocialError.self) {
            try await client.upload(video: video)
        }
        guard case .signInRequired = error else {
            Issue.record("A playable video was rejected before authentication: \(error)")
            return
        }
    }

    @Test func playableVideosOver80MBReachAuthentication() async throws {
        let folder = try TemporaryDirectory(prefix: "SocialUploadSize")
        let video = folder.appending(path: "synthetic.mp4")
        try FileManager.default.copyItem(at: TestFixtures.twoToneVideo(), to: video)
        let file = try FileHandle(forWritingTo: video)
        let originalSize = try file.seekToEnd()
        // A free atom keeps the synthetic MP4 playable while exercising a large upload.
        try file.write(contentsOf: Data([0x05, 0x00, 0x00, 0x00, 0x66, 0x72, 0x65, 0x65]))
        try file.truncate(atOffset: originalSize + 80 * 1024 * 1024)
        try file.close()
        let size = try #require(try video.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size > 80 * 1024 * 1024)
        #expect(abs(try await MediaPipeline.loadDuration(of: video) - 3) < 0.1)
        let error = try await #require(throws: SocialError.self) {
            try await client.upload(video: video)
        }
        guard case .signInRequired = error else {
            Issue.record("A playable video was rejected before authentication: \(error)")
            return
        }
    }
}

/// Two sequential exports against a real synthetic scene: a guest's suppression padding must not erase the host.
struct SocialExportTests {
    @Test @MainActor func aSecondPerformerKeepsTheFirstPerformersVoiceAndTheSceneTiming() async throws {
        let folder = scratchFolder("CoDubExport")
        let scene = try await CuratedSceneLoader.loadScene(manifestURL: try await SyntheticScene.make(in: folder))
        let ownerSetup = try await CuratedSceneStudio.makeSetup(scene: scene, characterID: "alice", barCount: 8, workingDirectory: folder.appending(path: "owner-work"))
        var ownerTakes: [Int: RecordedTake] = [:]
        for line in ownerSetup.script.lines(spokenBy: ownerSetup.characterID) {
            let url = folder.appending(path: "host-\(line.id).m4a")
            try ToneAudio.writeAAC(ToneAudio.tone(SyntheticScene.takeHz, amplitude: SyntheticScene.amplitude, seconds: 1.2, sampleRate: SyntheticScene.sampleRate), sampleRate: SyntheticScene.sampleRate, to: url)
            ownerTakes[line.id] = RecordedTake(url: url, duration: 1.2, inputSource: .microphone)
        }
        let ownerTimeline = try await DubProduction.makeTimeline(setup: ownerSetup, takes: ownerTakes)
        let firstVideo = folder.appending(path: "host-dub.mp4")
        _ = try await DubProduction.render(ownerTimeline, to: firstVideo)
        let source = SocialDubSource(video: firstVideo, setup: ownerSetup, takes: ownerTakes)
        let script = try source.invitationScript(guestCharacterId: 1)
        #expect(script.locale == scene.locale)
        #expect(script.ownerLinesRecorded == ownerTakes.count)
        let guestSetup = try script.setup(video: firstVideo, characterId: script.guestCharacterId, protectedSpans: script.protectedSpans)
        let guestHz = 2_600.0
        var guestTakes: [Int: RecordedTake] = [:]
        for line in guestSetup.script.lines(spokenBy: guestSetup.characterID) {
            let url = folder.appending(path: "guest-\(line.id).m4a")
            try ToneAudio.writeAAC(ToneAudio.tone(guestHz, amplitude: SyntheticScene.amplitude, seconds: 0.9, sampleRate: SyntheticScene.sampleRate), sampleRate: SyntheticScene.sampleRate, to: url)
            guestTakes[line.id] = RecordedTake(url: url, duration: 0.9, inputSource: .microphone)
        }
        let combinedTimeline = try await DubProduction.makeTimeline(setup: guestSetup, takes: guestTakes)
        let combinedVideo = folder.appending(path: "combined-dub.mp4")
        let report = try await DubProduction.render(combinedTimeline, to: combinedVideo)
        #expect(abs(report.videoDuration - scene.durationSeconds) <= report.frameDuration)
        let first = try await ToneAudio.render(AVURLAsset(url: firstVideo), audioMix: nil, sampleRate: SyntheticScene.sampleRate)
        let combined = try await ToneAudio.render(AVURLAsset(url: combinedVideo), audioMix: nil, sampleRate: SyntheticScene.sampleRate)
        for span in script.protectedSpans {
            let window = TimeSpan(start: span.start + 0.15, end: span.end - 0.04)
            let before = ToneAudio.power(ToneAudio.window(first, window, sampleRate: SyntheticScene.sampleRate), at: SyntheticScene.takeHz, sampleRate: SyntheticScene.sampleRate)
            let after = ToneAudio.power(ToneAudio.window(combined, window, sampleRate: SyntheticScene.sampleRate), at: SyntheticScene.takeHz, sampleRate: SyntheticScene.sampleRate)
            #expect(after > before * 0.7, "The first performer's voice must survive the second export")
        }
        // This window is inside the guest's 120 ms suppression padding but still belongs to the host's take.
        let edge = TimeSpan(start: 2.09, end: 2.16)
        let edgeBefore = ToneAudio.power(ToneAudio.window(first, edge, sampleRate: SyntheticScene.sampleRate), at: SyntheticScene.takeHz, sampleRate: SyntheticScene.sampleRate)
        let edgeAfter = ToneAudio.power(ToneAudio.window(combined, edge, sampleRate: SyntheticScene.sampleRate), at: SyntheticScene.takeHz, sampleRate: SyntheticScene.sampleRate)
        #expect(edgeAfter > edgeBefore * 0.7)
        let guestWindow = TimeSpan(start: 2.4, end: 2.8)
        #expect(ToneAudio.power(ToneAudio.window(combined, guestWindow, sampleRate: SyntheticScene.sampleRate), at: guestHz, sampleRate: SyntheticScene.sampleRate) > 0.005)
    }
}
