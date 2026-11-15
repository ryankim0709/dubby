import AVFoundation
import Testing
@testable import Dubbing

@MainActor
struct DubbingTests {
    @Test func contentViewBuilds() {
        _ = ContentView().body
    }

    @Test func bundledScenesAreDubbable() {
        for scene in SampleData.scenes {
            #expect(scene.validationIssues.isEmpty, "\(scene.id): \(scene.validationIssues)")
            for character in scene.characters {
                #expect(!scene.lines(for: character.id).isEmpty, "\(scene.id) has no lines for \(character.id)")
            }
        }
    }

    /// Every word a learner can see in a line has a meaning in each home language that needs one.
    @Test func everyWordHasAMeaningForLearners() {
        for scene in SampleData.scenes {
            for language in HomeLanguage.allCases where scene.needsTranslation(for: language) {
                for line in scene.lines {
                    #expect(scene.translation(of: line, into: language) != nil, "\(line.id) has no \(language.rawValue) translation")
                    for word in line.text.split(separator: " ") {
                        #expect(scene.meaning(of: String(word), in: language) != nil, "“\(word)” in \(line.id) has no \(language.rawValue) meaning")
                    }
                }
            }
        }
    }

    @Test func glossaryKeysIgnorePunctuationAndCase() {
        #expect(Glossary.key(for: "¿Quién") == "quién")
        #expect(Glossary.key(for: "me!") == "me")
        #expect(Glossary.key(for: "It's") == "it's")
    }

    @Test func validationCatchesBrokenTimingAndCasting() {
        let base = SampleData.laCarta
        let broken = SceneClip(
            id: base.id,
            title: base.title,
            source: base.source,
            synopsis: base.synopsis,
            language: base.language,
            languageCode: base.languageCode,
            duration: base.duration,
            difficulty: base.difficulty,
            artwork: base.artwork,
            characters: base.characters,
            lines: [
                ScriptLine(id: "past-end", characterID: "sofia", text: "x", translations: [:], start: 9, end: 12),
                ScriptLine(id: "reversed", characterID: "sofia", text: "x", translations: [:], start: 4, end: 3),
                ScriptLine(id: "stranger", characterID: "nobody", text: "x", translations: [:], start: 1, end: 2),
            ],
            media: SceneMediaFiles(video: base.media.video, bed: base.media.bed, stems: ["sofia": "la-carta-sofia.m4a"]),
            dubCount: 0,
            glossary: [:]
        )
        #expect(Set(broken.validationIssues) == [
            .invalidTiming(lineID: "past-end"),
            .invalidTiming(lineID: "reversed"),
            .unknownCharacter(lineID: "stranger"),
            .missingStem(characterID: "mateo"),
        ])
    }

    @Test func rmsBinsMeasureEachWindow() {
        let bins = Waveform.rmsBins(samples: [0, 0, 1, -1, 0.5], binSize: 2)
        #expect(bins.count == 3)
        #expect(bins[0] == 0)
        #expect(bins[1] == 1)
        #expect(abs(bins[2] - 0.5) < 0.0001)
    }

    /// An envelope of room noise with a voiced stretch, at 100 bins per second.
    private func take(voicedFrom start: Double, to end: Double, length: Double) -> Envelope {
        let binDuration = 0.01
        let values = (0..<Int(length / binDuration)).map { index -> Float in
            let time = Double(index) * binDuration
            return time >= start && time < end ? 0.2 : 0.004
        }
        return Envelope(values: values, binDuration: binDuration)
    }

    @Test func onCueTakeScoresFullMarks() {
        // Capture starts 2s before a line at 5.0–7.0; the voice comes in right on it.
        let timing = TimingAnalyzer.assess(take: take(voicedFrom: 2.0, to: 4.0, length: 5.8), takeSceneStart: 3.0, lineStart: 5.0, lineEnd: 7.0)
        #expect(timing.verdict == .onCue)
        #expect(timing.score == 100)
    }

    @Test func lateTakeIsCalledLateAndScoredLower() {
        let timing = TimingAnalyzer.assess(take: take(voicedFrom: 2.6, to: 4.6, length: 5.8), takeSceneStart: 3.0, lineStart: 5.0, lineEnd: 7.0)
        #expect(timing.verdict == .late)
        guard case .measured(let onset, _) = timing else {
            Issue.record("Expected a measured take")
            return
        }
        #expect(abs(onset - 0.6) < 0.02)
        #expect((timing.score ?? 100) < 80)
    }

    @Test func earlyAndOverlongTakesAreDistinguished() {
        let early = TimingAnalyzer.assess(take: take(voicedFrom: 1.4, to: 3.4, length: 5.8), takeSceneStart: 3.0, lineStart: 5.0, lineEnd: 7.0)
        #expect(early.verdict == .early)
        let long = TimingAnalyzer.assess(take: take(voicedFrom: 2.0, to: 5.0, length: 5.8), takeSceneStart: 3.0, lineStart: 5.0, lineEnd: 7.0)
        #expect(long.verdict == .long)
    }

    @Test func silentTakeHasNoScore() {
        let silence = Envelope(values: Array(repeating: 0.003, count: 300), binDuration: 0.01)
        let timing = TimingAnalyzer.assess(take: silence, takeSceneStart: 0, lineStart: 1, lineEnd: 2)
        #expect(timing == .noSpeech)
        #expect(timing.score == nil)
    }

    /// Dubbing Anakin keeps the picture, the music bed, and Obi-Wan, and drops only Anakin's stem.
    @Test func compositionReplacesOnlyTheSelectedCharacter() async throws {
        let scene = SampleData.underestimate
        let composition = try await SceneComposer.composition(for: scene, voicing: ["obiwan"], takes: [])
        // A mutable composition's tracks are known synchronously; no async load is needed.
        #expect(composition.tracks(withMediaType: .video).count == 1)
        #expect(composition.tracks(withMediaType: .audio).count == 2)
        #expect(abs(composition.duration.seconds - scene.duration) < 0.1)
    }

    @Test func originalStemWaveformCoversItsLines() async throws {
        let scene = SampleData.underestimate
        let url = try MediaLibrary.url(for: try #require(scene.media.stems["anakin"]))
        let envelope = try await Waveform.envelope(of: url, binsPerSecond: 60)
        let firstLine = try #require(scene.lines(for: "anakin").first)
        let timing = TimingAnalyzer.assess(take: envelope, takeSceneStart: 0, lineStart: firstLine.start, lineEnd: firstLine.end)
        guard case .measured(let onset, _) = timing else {
            Issue.record("The bundled stem should contain speech")
            return
        }
        #expect(abs(onset) < 0.1)
    }

    /// Smoke test of the studio loop without the UI: record a line, get the instant replay,
    /// and land in review with a pending take. Needs microphone access on the simulator.
    @Test func recordingALineEndsInReview() async throws {
        let engine = StudioEngine(scene: SampleData.underestimate, character: SampleData.anakin)
        await engine.prepare()
        #expect(engine.phase == .ready)
        await engine.record()
        #expect(engine.alert == nil, "\(String(describing: engine.alert))")
        #expect(engine.phase == .recording)
        // Capture runs to the line's end plus its tail, then the take replays the same window.
        let deadline = Date.now.addingTimeInterval(20)
        while engine.phase != .reviewing && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(engine.phase == .reviewing)
        #expect(engine.pending != nil)
    }
}
