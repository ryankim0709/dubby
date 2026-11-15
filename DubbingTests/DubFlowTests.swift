import AVFoundation
import Foundation
import Testing
@testable import Dubbing

struct ScriptBuilderTests {
    @Test func splitsLinesAtSentenceEndsAndLongPauses() {
        let words = [
            TranscribedWord(text: "Your", start: 0.5, end: 0.8),
            TranscribedWord(text: "empire?", start: 0.8, end: 1.4),
            TranscribedWord(text: "Don't", start: 1.45, end: 1.7),
            TranscribedWord(text: "move", start: 1.7, end: 2.0),
            TranscribedWord(text: "now", start: 3.2, end: 3.5),
        ]
        let lines = ScriptBuilder.segmentLines(words: words, pauseThreshold: 0.7, sentencePause: 0)
        #expect(lines.map(\.text) == ["Your empire?", "Don't move", "now"])
        #expect(lines.map(\.start) == [0.5, 1.45, 3.2])
    }

    @Test func trimsTakesAtTheNextLineAndReportsTheCut() {
        let lines = [
            ScriptLine(id: 0, text: "Mine", start: 1, end: 2, speakerID: 0, envelope: []),
            ScriptLine(id: 1, text: "Theirs", start: 2.4, end: 4, speakerID: 1, envelope: []),
            ScriptLine(id: 2, text: "Mine again", start: 6, end: 7, speakerID: 0, envelope: []),
        ]
        let takes = [
            0: RecordedTake(url: URL(filePath: "/take-0.m4a"), duration: 3),
            2: RecordedTake(url: URL(filePath: "/take-2.m4a"), duration: 1.5),
        ]
        let placements = ScriptBuilder.takePlacements(lines: lines, takes: takes, sectionDuration: 10, grace: 0.75)
        // Line 0 must stop where line 1 starts; line 2's take fits within its grace.
        #expect(placements.map(\.start) == [1, 6])
        #expect(placements.map(\.duration) == [1.4, 1.5])
        #expect(abs(placements[0].trimmedSeconds - 1.6) < 1e-9)
        #expect(placements[1].trimmedSeconds == 0)

        let spans = ScriptBuilder.suppressionSpans(placements: placements, padding: 0.1, sectionDuration: 7.5)
        #expect(spans == [TimeSpan(start: 0.9, end: 2.5), TimeSpan(start: 5.9, end: 7.5)])
    }

    @Test func dragsKeepTheSectionWithinLimits() {
        let origin = TimeSpan(start: 10, end: 20)
        #expect(SectionEditing.adjusted(origin: origin, handle: .end, delta: 30, clipDuration: 60) == TimeSpan(start: 10, end: 40))
        #expect(SectionEditing.adjusted(origin: origin, handle: .start, delta: 15, clipDuration: 60) == TimeSpan(start: 18, end: 20))
        #expect(SectionEditing.adjusted(origin: origin, handle: .move, delta: 45, clipDuration: 50) == TimeSpan(start: 40, end: 50))
    }
}

struct VoicePrintTests {
    @Test func groupsLinesBySoundingVoice() throws {
        let sampleRate = 16_000.0
        // Two synthetic "voices": a bright buzz rich in harmonics and a dull, nearly pure tone.
        let bright = Synthetic.buzz(frequency: 140, harmonics: 25, seconds: 1, sampleRate: sampleRate)
        let dull = Synthetic.buzz(frequency: 220, harmonics: 1, seconds: 1, sampleRate: sampleRate)
        let prints = try [bright, dull, bright, dull, nil].map { samples in
            try samples.flatMap { try VoicePrint.features(samples: $0, sampleRate: sampleRate) }
        }
        // The last line has no audio, so it inherits the previous line's voice.
        #expect(VoicePrint.clusterSpeakers(prints: prints, speakerCount: 2) == [0, 1, 0, 1, 1])
    }
}

struct SpeechBandFilterTests {
    @Test func removesTheSpeechBandAndKeepsBass() throws {
        let sampleRate = 44_100.0
        let bass = Synthetic.buzz(frequency: 80, harmonics: 1, seconds: 1, sampleRate: sampleRate)
        let speech = Synthetic.buzz(frequency: 1_000, harmonics: 1, seconds: 1, sampleRate: sampleRate)
        let mixed = zip(bass, speech).map(+)
        let filtered = try SpeechBandFilter.apply(to: mixed, sampleRate: sampleRate)
        // Skip the filter's settling time at the start.
        let settled = Array(filtered[4_410...])
        let original = Array(mixed[4_410...])
        #expect(Synthetic.power(settled, at: 1_000, sampleRate: sampleRate) < Synthetic.power(original, at: 1_000, sampleRate: sampleRate) * 0.01)
        #expect(Synthetic.power(settled, at: 80, sampleRate: sampleRate) > Synthetic.power(original, at: 80, sampleRate: sampleRate) * 0.8)
    }
}

struct PracticeStatsTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func day(_ offset: Int, from today: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: today) ?? today
    }

    @Test func streakCountsConsecutiveDaysAndSurvivesUntilTonight() {
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12)) ?? .now
        let dates = [day(0, from: today), day(-1, from: today), day(-1, from: today), day(-3, from: today)]
        #expect(PracticeStats.currentStreak(dates: dates, today: today, calendar: calendar) == 2)
        // No dub yet today, but yesterday's keeps the streak alive.
        #expect(PracticeStats.currentStreak(dates: [day(-1, from: today), day(-2, from: today)], today: today, calendar: calendar) == 2)
        #expect(PracticeStats.currentStreak(dates: [day(-2, from: today)], today: today, calendar: calendar) == 0)
        #expect(PracticeStats.bestStreak(dates: dates + [day(-4, from: today), day(-5, from: today)], calendar: calendar) == 3)
    }
}

struct DubLibraryTests {
    @Test func savesAndReloadsDubsNewestFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DubLibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        #expect(try DubLibrary.load(from: folder).isEmpty)

        let video = try Synthetic.audioFile(
            samples: [0, 0, 0],
            sampleRate: 44_100,
            url: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).caf")
        )
        let first = Synthetic.savedDub(title: "First")
        let second = Synthetic.savedDub(title: "Second")
        _ = try DubLibrary.save(video: video, as: first, in: folder)
        _ = try DubLibrary.save(video: video, as: second, in: folder)

        let loaded = try DubLibrary.load(from: folder)
        #expect(loaded.map(\.sceneTitle) == ["Second", "First"])
        #expect(FileManager.default.fileExists(atPath: DubLibrary.videoURL(for: first, in: folder).path(percentEncoded: false)))
    }

    @Test func titlesComeFromFileNames() {
        #expect(MediaLibrary.title(forFileName: "anakin-confronts-obi-wan") == "Anakin Confronts Obi Wan")
    }
}

struct DubExportTests {
    @Test func filtersTheOriginalDialogueOnlyUnderTheTake() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DubExportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = try Synthetic.twoToneVideo()
        let silentTake = try Synthetic.audioFile(
            samples: [Float](repeating: 0, count: 44_100),
            sampleRate: 44_100,
            url: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).caf")
        )
        let section = ClipSection(start: 0.5, end: 2.5)
        let sceneAudio = folder.appending(path: "scene.m4a")
        let background = folder.appending(path: "background.caf")
        try await MediaPipeline.exportAudio(from: source, section: section, to: sceneAudio)
        try await MediaPipeline.renderDialogueSuppressed(from: sceneAudio, to: background)
        let placements = [TakePlacement(url: silentTake, start: 0.5, duration: 0.8, lineEnd: 1.3, trimmedSeconds: 0)]
        let spans = ScriptBuilder.suppressionSpans(placements: placements, padding: 0.1, sectionDuration: section.duration)
        let dub = folder.appending(path: "dub.mp4")

        try await MediaPipeline.exportDub(
            source: source,
            section: section,
            dialogueSuppressed: background,
            placements: placements,
            suppressionSpans: spans,
            to: dub
        )

        #expect(abs(try await MediaPipeline.loadDuration(of: dub) - section.duration) < 0.1)
        let dubAudio = folder.appending(path: "dub.m4a")
        try await MediaPipeline.exportAudio(from: dub, section: ClipSection(start: 0, end: section.duration), to: dubAudio)
        let audio = try MediaPipeline.readMonoAudio(from: dubAudio)
        func window(_ start: Double, _ end: Double) -> [Float] {
            Array(audio.samples[Int(start * audio.sampleRate)..<Int(end * audio.sampleRate)])
        }
        let underTake = window(0.75, 1.15)
        let outside = window(1.55, 1.95)
        let rate = audio.sampleRate
        #expect(
            Synthetic.power(underTake, at: 1_000, sampleRate: rate) < Synthetic.power(outside, at: 1_000, sampleRate: rate) * 0.02,
            "the speech band should be filtered out under the take"
        )
        #expect(
            Synthetic.power(underTake, at: 80, sampleRate: rate) > Synthetic.power(outside, at: 80, sampleRate: rate) * 0.5,
            "bass should carry on under the take"
        )
    }
}

/// Synthetic media so tests never depend on copyrighted clips.
private enum Synthetic {
    static func buzz(frequency: Double, harmonics: Int, seconds: Double, sampleRate: Double) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { index in
            let time = Double(index) / sampleRate
            let wave = (1...harmonics).reduce(0.0) { $0 + sin(2 * .pi * frequency * Double($1) * time) / Double($1) }
            return Float(0.3 * wave)
        }
    }

    /// Power at one frequency (Goertzel), normalized by length so windows of any size compare.
    static func power(_ samples: [Float], at frequency: Double, sampleRate: Double) -> Double {
        let coefficient = 2 * cos(2 * .pi * frequency / sampleRate)
        var previous = 0.0
        var beforePrevious = 0.0
        for sample in samples {
            let current = Double(sample) + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
        return power / Double(samples.count * samples.count)
    }

    static func audioFile(samples: [Float], sampleRate: Double, url: URL) throws -> URL {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try #require(buffer.floatChannelData?[0])
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    static func savedDub(title: String) -> SavedDub {
        let id = UUID()
        return SavedDub(
            id: id,
            sceneTitle: title,
            characterName: "Speaker 1",
            linesDubbed: 2,
            totalLines: 3,
            sceneSeconds: 12,
            createdAt: .now,
            videoFileName: "\(id.uuidString).mp4"
        )
    }

    /// `Fixtures/two-tone-3s.mp4`: 3 s of black 64×64 H.264 video with 80 Hz and 1 kHz tones, generated with ffmpeg.
    static func twoToneVideo() throws -> URL {
        try #require(Bundle(for: FixtureBundle.self).url(forResource: "two-tone-3s", withExtension: "mp4"))
    }
}

/// Anchors `Bundle(for:)` to the test bundle, where the fixtures are copied.
private final class FixtureBundle {}
