import AVFoundation
import Foundation
import Testing
@testable import Dubbing

/// Explicit timing decisions: cue, recording window, placement, trims, gaps and overlaps.
struct DubTimingTests {
    private let rules = DubTimingRules.standard

    private func line(_ id: Int, speaker: Int, _ start: Double, _ end: Double) -> ScriptLine {
        ScriptLine(id: id, text: "Line \(id)", start: start, end: end, speakerID: speaker, envelope: [])
    }

    private func take(_ seconds: Double) -> RecordedTake {
        RecordedTake(url: URL(filePath: "/take-\(seconds).m4a"), duration: seconds, inputSource: .microphone)
    }

    @Test func cueAndRecordingWindowsAreExplicit() {
        let lines = [line(0, speaker: 0, 1, 2), line(1, speaker: 1, 2.4, 4), line(2, speaker: 0, 2.6, 3)]
        let clip = LineTiming.make(for: lines[0], in: lines, boundary: .nextLineOfAnyone, sceneDuration: 10, rules: rules)
        #expect(clip.cueStart == 0)
        #expect(clip.line == TimeSpan(start: 1, end: 2))
        #expect(clip.graceEnd == 2.75)
        #expect(clip.limit == .nextLine(1))
        #expect(clip.placementLimit == 2.4)
        // A raw clip records to the grace end and lets export report the cut, as the studio always has.
        #expect(clip.recordingWindow == TimeSpan(start: 1, end: 2.75))

        let curated = LineTiming.make(for: lines[0], in: lines, boundary: .nextLineOfSameCharacter, sceneDuration: 10, rules: rules)
        #expect(curated.limit == .nextLine(2))
        #expect(curated.placementLimit == 2.6)
        // A curated scene records exactly what export can place.
        #expect(curated.recordingWindow == TimeSpan(start: 1, end: 2.6))

        let late = LineTiming.make(for: line(3, speaker: 0, 8, 9.6), in: lines, boundary: .nextLineOfSameCharacter, sceneDuration: 10, rules: rules)
        #expect(late.cueStart == 6.5)
        #expect(late.limit == .sceneEnd)
        #expect(late.placementLimit == 10)
    }

    @Test func rawClipDecisionsMatchTheExistingPlacements() {
        let lines = [line(0, speaker: 0, 1, 2), line(1, speaker: 1, 2.4, 4), line(2, speaker: 0, 6, 7)]
        let takes = [0: take(3), 2: take(1.5)]
        let decisions = TakeDecision.decide(lines: lines, takes: takes, boundary: .nextLineOfAnyone, sceneDuration: 10, rules: rules)
        let placements = ScriptBuilder.takePlacements(lines: lines, takes: takes, sectionDuration: 10, grace: rules.lineGrace)
        #expect(decisions.map(\.start) == placements.map(\.start))
        #expect(decisions.map(\.placedSeconds) == placements.map(\.duration))
        #expect(decisions.map(\.trimmedSeconds) == placements.map(\.trimmedSeconds))
        #expect(decisions[0].trimmedBy == .nextLine(1))
        #expect(decisions[1].trimmedBy == nil)
    }

    @Test func curatedTakesReportTrimsGapsAndOverlapsWithoutShiftingTheTimeline() {
        let lines = [
            line(0, speaker: 0, 1, 2),
            line(1, speaker: 1, 2.2, 3),
            line(2, speaker: 0, 2.5, 3.5),
            line(3, speaker: 0, 9, 9.8),
        ]
        let takes = [0: take(1.8), 2: take(0.6), 3: take(1.5)]
        let decisions = TakeDecision.decide(lines: lines, takes: takes, boundary: .nextLineOfSameCharacter, sceneDuration: 10, rules: rules)
        #expect(decisions.map(\.lineID) == [0, 2, 3])
        #expect(decisions.map(\.start) == [1, 2.5, 9])

        // Line 0 runs 1.8 s but Alice's next line starts at 2.5: cut there, and it overlaps Bob's line 1.
        #expect(decisions[0].placedSeconds == 1.5)
        #expect(decisions[0].trimmedBy == .nextLine(2))
        #expect(abs(decisions[0].trimmedSeconds - 0.3) < 1e-9)
        #expect(decisions[0].overlappedLineIDs == [1])
        #expect(decisions[0].silentGapSeconds == 0)

        // Line 2's take is shorter than the line: the rest of the line stays silent for Alice.
        #expect(decisions[1].trimmedBy == nil)
        #expect(abs(decisions[1].silentGapSeconds - 0.4) < 1e-9)

        // Line 3 runs past the scene end.
        #expect(decisions[2].trimmedBy == .sceneEnd)
        #expect(abs(decisions[2].placedSeconds - 1) < 1e-9)
    }

    @Test func gainEnvelopesFollowAudioMixSemantics() {
        let muted = GainEnvelope.muted(during: [TimeSpan(start: 1, end: 2)], rampLength: 0.1)
        #expect(muted.gain(at: 0.5) == 1)
        #expect(abs(muted.gain(at: 1.05) - 0.5) < 1e-6)
        #expect(muted.gain(at: 1.5) == 0)
        #expect(muted.gain(at: 2.5) == 1)
        let audible = GainEnvelope.audible(during: [TimeSpan(start: 1, end: 2)], rampLength: 0.1)
        #expect(audible.gain(at: 0.5) == 0)
        #expect(audible.gain(at: 1.5) == 1)
    }
}

/// End to end on the SYNTHETIC scene: export a dub of Alice with two kept takes and measure the MP4 spectrally.
struct CuratedDubExportTests {
    private let rate = SyntheticScene.sampleRate
    /// A source counts as present at a quarter of its full level and absent below 1/100 of it (20 dB down).
    private let fullLevel = Double(SyntheticScene.amplitude / 2) * Double(SyntheticScene.amplitude / 2)

    private struct Fixture {
        let setup: DubSetup
        let takes: [Int: RecordedTake]
        let timeline: DubTimeline
        let folder: URL
    }

    /// Alice's line 1 (1.0–2.0 s) gets a 1.2 s take, line 3 (3.6–4.6 s) a 0.7 s take, line 5 (6.6–7.6 s) none.
    private func makeFixture(_ name: String) async throws -> Fixture {
        let folder = scratchFolder(name)
        let scene = try await CuratedSceneLoader.loadScene(manifestURL: try await SyntheticScene.make(in: folder))
        let setup = try await CuratedSceneStudio.makeSetup(scene: scene, characterID: "alice", barCount: 8, workingDirectory: folder.appending(path: "work"))
        var takes: [Int: RecordedTake] = [:]
        for (lineIndex, seconds) in [(0, 1.2), (2, 0.7)] {
            let url = folder.appending(path: "take-\(lineIndex).m4a")
            try ToneAudio.writeAAC(ToneAudio.tone(SyntheticScene.takeHz, amplitude: SyntheticScene.amplitude, seconds: seconds, sampleRate: rate), sampleRate: rate, to: url)
            takes[lineIndex] = RecordedTake(url: url, duration: seconds, inputSource: .microphone)
        }
        let timeline = try await DubProduction.makeTimeline(setup: setup, takes: takes)
        return Fixture(setup: setup, takes: takes, timeline: timeline, folder: folder)
    }

    private func level(_ samples: [Float], _ hertz: Double, _ start: Double, _ end: Double) -> Double {
        ToneAudio.power(ToneAudio.window(samples, TimeSpan(start: start, end: end), sampleRate: rate), at: hertz, sampleRate: rate)
    }

    private func expectPresent(_ samples: [Float], _ hertz: Double, _ start: Double, _ end: Double, _ what: String) {
        let measured = level(samples, hertz, start, end)
        #expect(measured > fullLevel / 4, "\(what) should be audible in \(start)–\(end) s (measured \(measured), full \(fullLevel))")
    }

    private func expectAbsent(_ samples: [Float], _ hertz: Double, _ start: Double, _ end: Double, _ what: String) {
        let measured = level(samples, hertz, start, end)
        #expect(measured < fullLevel / 100, "\(what) should be silent in \(start)–\(end) s (measured \(measured), full \(fullLevel))")
    }

    @Test func replacesOnlyTheSelectedCharacterUnderKeptTakes() async throws {
        let fixture = try await makeFixture("CuratedDubExport")
        let output = fixture.folder.appending(path: "dub.mp4")
        let report = try await DubProduction.render(fixture.timeline, to: output)
        #expect(abs(report.videoDuration - SyntheticScene.duration) <= report.frameDuration)
        #expect(abs(report.audioDuration - SyntheticScene.duration) <= report.frameDuration)

        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let audio = try await ToneAudio.render(asset, audioMix: nil, sampleRate: rate)

        // Background throughout.
        for start in stride(from: 0.2, to: 9.6, by: 0.6) {
            expectPresent(audio, SyntheticScene.backgroundHz, start, start + 0.4, "the background")
        }
        // Bob, the other character, in each of his windows.
        for (start, end) in [(2.35, 3.05), (5.15, 5.85), (8.15, 8.85)] {
            expectPresent(audio, SyntheticScene.bobHz, start, end, "Bob")
        }
        // Alice's original is gone under both kept takes, including the gap after the short take on line 3...
        expectAbsent(audio, SyntheticScene.aliceHz, 1.15, 1.85, "Alice's original under the line 1 take")
        expectAbsent(audio, SyntheticScene.aliceHz, 3.75, 4.5, "Alice's original under and after the line 3 take")
        // ...and plays where no take covers her line.
        expectPresent(audio, SyntheticScene.aliceHz, 6.75, 7.45, "Alice's original on line 5")
        // The takes sit at their placements and nowhere else.
        expectPresent(audio, SyntheticScene.takeHz, 1.1, 2.1, "the line 1 take")
        expectPresent(audio, SyntheticScene.takeHz, 3.7, 4.2, "the line 3 take")
        expectAbsent(audio, SyntheticScene.takeHz, 0.2, 0.9, "takes before line 1")
        expectAbsent(audio, SyntheticScene.takeHz, 4.45, 6.5, "takes after the line 3 take")
        expectAbsent(audio, SyntheticScene.takeHz, 6.75, 7.45, "takes on line 5")

        // Each take starts at its line start within 30 ms.
        let firstOnset = try #require(ToneAudio.onset(of: SyntheticScene.takeHz, in: audio, from: 0.8, steady: TimeSpan(start: 1.3, end: 1.9), sampleRate: rate))
        let secondOnset = try #require(ToneAudio.onset(of: SyntheticScene.takeHz, in: audio, from: 3.4, steady: TimeSpan(start: 3.8, end: 4.1), sampleRate: rate))
        #expect(abs(firstOnset - 1.0) <= 0.03, "line 1 take starts at \(firstOnset) s")
        #expect(abs(secondOnset - 3.6) <= 0.03, "line 3 take starts at \(secondOnset) s")

        // Every decision is stated: the short take leaves a reported gap; nothing was trimmed.
        #expect(fixture.timeline.decisions.map(\.lineID) == [0, 2])
        #expect(fixture.timeline.decisions.allSatisfy { $0.trimmedBy == nil })
        #expect(abs(fixture.timeline.decisions[1].silentGapSeconds - 0.3) < 1e-9)
    }

    @Test @MainActor func previewPlaysTheSameTimelineAsTheExport() async throws {
        let fixture = try await makeFixture("CuratedDubPreview")
        // The timeline is a value computed from the setup and takes alone.
        #expect(try await DubProduction.makeTimeline(setup: fixture.setup, takes: fixture.takes) == fixture.timeline)

        let item = try await DubRenderer.makePreviewItem(for: fixture.timeline)
        let previewAudio = try await ToneAudio.render(item.asset, audioMix: item.audioMix, sampleRate: rate)
        let output = fixture.folder.appending(path: "dub.mp4")
        _ = try await DubProduction.render(fixture.timeline, to: output)
        let exportAudio = try await ToneAudio.render(AVURLAsset(url: output), audioMix: nil, sampleRate: rate)

        #expect(abs(try await item.asset.load(.duration).seconds - SyntheticScene.duration) < 1.0 / 30)
        let tones = [SyntheticScene.backgroundHz, SyntheticScene.aliceHz, SyntheticScene.bobHz, SyntheticScene.takeHz]
        for start in stride(from: 0.1, to: 9.6, by: 0.3) {
            for hertz in tones {
                let preview = level(previewAudio, hertz, start, start + 0.3)
                let exported = level(exportAudio, hertz, start, start + 0.3)
                // Equal within a factor of two, or within 2% of a full tone where both are near silence.
                #expect(
                    abs(exported - preview) < fullLevel / 50 || (exported > preview / 2 && exported < preview * 2),
                    "\(hertz) Hz at \(start) s: preview \(preview), export \(exported)"
                )
            }
        }
    }
}
