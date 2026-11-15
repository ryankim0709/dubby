import Foundation

/// The timing values every part of a dub agrees on: the studio's cue and recording window, where export places a
/// take, and how the original dialogue gives way to it. Built from `DubTiming` so the existing studio warnings match.
nonisolated struct DubTimingRules: Hashable, Sendable {
    /// Seconds of the scene played before a line so the learner hears their cue.
    let cueLength: Double
    /// Seconds a take may run past the end of its line.
    let lineGrace: Double
    /// Seconds the selected character's original dialogue is muted before and after each take.
    let suppressionPadding: Double
    /// Cuts shorter than this are breath or room tone, not speech worth reporting.
    let noticeableTrim: Double
    /// Length of each volume ramp when the original dialogue gives way to a take and back.
    let rampLength: Double

    static let standard = DubTimingRules(
        cueLength: DubTiming.cueLength,
        lineGrace: DubTiming.lineGrace,
        suppressionPadding: DubTiming.suppressionPadding,
        noticeableTrim: DubTiming.noticeableTrim,
        rampLength: 0.08
    )
}

/// Which later line stops a take that runs long.
nonisolated enum TakeBoundary: Hashable, Sendable {
    /// Raw clips: under a take the whole original is speech-band filtered, so a take that ran into anyone's next line
    /// would filter that speaker too. A take stops at the next line of any speaker.
    case nextLineOfAnyone
    /// Curated scenes: every other character keeps their own dialogue track, so only the same character's next line
    /// or the scene end stops a take. Running over another character's line is kept and reported as an overlap.
    case nextLineOfSameCharacter
}

/// What set the latest point a take may reach.
nonisolated enum TakeLimit: Hashable, Sendable {
    /// The line's end plus the grace.
    case grace
    /// The start of the line with this id.
    case nextLine(Int)
    case sceneEnd
}

/// The explicit timing of one line, in seconds from the scene (or section) start.
nonisolated struct LineTiming: Hashable, Sendable {
    let lineID: Int
    /// Where cue playback starts: `cueLength` before the line, never before the scene.
    let cueStart: Double
    /// The original line.
    let line: TimeSpan
    /// The line's end plus the grace, before any other limit applies.
    let graceEnd: Double
    /// The latest point a placed take may reach, and what set it.
    let placementLimit: Double
    let limit: TakeLimit
    /// What the studio records: from the line start (after the cue) to the end of this window.
    let recordingWindow: TimeSpan

    var allowedTakeDuration: Double { max(0, placementLimit - line.start) }

    /// For `.nextLineOfAnyone` this matches `ScriptBuilder.allowedTakeDuration` and the baseline studio, which records
    /// until the grace end and lets export cut the rest. For `.nextLineOfSameCharacter` the studio records exactly
    /// what export can place, so nothing recorded is dropped.
    static func make(for line: ScriptLine, in lines: [ScriptLine], boundary: TakeBoundary, sceneDuration: Double, rules: DubTimingRules) -> LineTiming {
        let candidates = lines.filter { other in
            other.start > line.start && (boundary == .nextLineOfAnyone || other.speakerID == line.speakerID)
        }
        let next = candidates.min { $0.start < $1.start }
        let graceEnd = line.end + rules.lineGrace
        var limit = TakeLimit.grace
        var placementLimit = graceEnd
        if let next, next.start < placementLimit {
            limit = .nextLine(next.id)
            placementLimit = next.start
        }
        if sceneDuration < placementLimit {
            limit = .sceneEnd
            placementLimit = sceneDuration
        }
        let recordingEnd = boundary == .nextLineOfAnyone ? min(graceEnd, sceneDuration) : placementLimit
        return LineTiming(
            lineID: line.id,
            cueStart: max(0, line.start - rules.cueLength),
            line: TimeSpan(start: line.start, end: line.end),
            graceEnd: graceEnd,
            placementLimit: placementLimit,
            limit: limit,
            recordingWindow: TimeSpan(start: line.start, end: max(line.start, recordingEnd))
        )
    }
}

/// What export does with one kept take, stated so the app can report it instead of trimming silently.
/// A take always starts at its line's start; the scene timeline never shifts.
nonisolated struct TakeDecision: Hashable, Sendable {
    let lineID: Int
    let url: URL
    let start: Double
    let recordedSeconds: Double
    let placedSeconds: Double
    /// Set when the take was cut, naming what cut it.
    let trimmedBy: TakeLimit?
    /// Seconds between the end of the take and the end of its line. That character is silent there: the actor's
    /// original is not brought back mid-line.
    let silentGapSeconds: Double
    /// Other characters' lines the placed take overlaps; both voices play there.
    let overlappedLineIDs: [Int]

    var end: Double { start + placedSeconds }
    var trimmedSeconds: Double { recordedSeconds - placedSeconds }
    var isTrimNoticeable: Bool { trimmedSeconds > DubTiming.noticeableTrim }

    /// Decides every kept take's placement. Takes for lines not in `lines` and takes too short to place are skipped.
    static func decide(
        lines: [ScriptLine],
        takes: [Int: RecordedTake],
        boundary: TakeBoundary,
        sceneDuration: Double,
        rules: DubTimingRules
    ) -> [TakeDecision] {
        lines.sorted { $0.start < $1.start }.compactMap { line in
            guard let take = takes[line.id] else { return nil }
            let timing = LineTiming.make(for: line, in: lines, boundary: boundary, sceneDuration: sceneDuration, rules: rules)
            let placed = min(take.duration, timing.allowedTakeDuration)
            guard placed > 0 else { return nil }
            let end = line.start + placed
            return TakeDecision(
                lineID: line.id,
                url: take.url,
                start: line.start,
                recordedSeconds: take.duration,
                placedSeconds: placed,
                trimmedBy: take.duration > placed ? timing.limit : nil,
                silentGapSeconds: max(0, line.end - end),
                overlappedLineIDs: lines
                    .filter { $0.speakerID != line.speakerID && $0.start < end && $0.end > line.start }
                    .map(\.id)
            )
        }
    }
}

/// Volume over time for one audio layer: a starting gain, then ramps. Between ramps the gain holds the last
/// ramp's end value, which is how `AVMutableAudioMixInputParameters` behaves.
nonisolated struct GainEnvelope: Hashable, Sendable {
    let initial: Float
    let ramps: [GainRamp]

    static let full = GainEnvelope(initial: 1, ramps: [])

    func gain(at time: Double) -> Float {
        var value = initial
        for ramp in ramps.sorted(by: { $0.span.start < $1.span.start }) {
            guard time >= ramp.span.start else { break }
            guard time >= ramp.span.end else {
                let progress = Float((time - ramp.span.start) / (ramp.span.end - ramp.span.start))
                return ramp.from + (ramp.to - ramp.from) * progress
            }
            value = ramp.to
        }
        return value
    }

    /// Full gain except inside `spans`, where it ramps down to silence and back up.
    static func muted(during spans: [TimeSpan], rampLength: Double) -> GainEnvelope {
        GainEnvelope(initial: 1, ramps: crossfade(spans: spans, rampLength: rampLength, inside: 0, outside: 1))
    }

    /// Silent except inside `spans`, where it ramps up to full gain and back down.
    static func audible(during spans: [TimeSpan], rampLength: Double) -> GainEnvelope {
        GainEnvelope(initial: 0, ramps: crossfade(spans: spans, rampLength: rampLength, inside: 1, outside: 0))
    }

    private static func crossfade(spans: [TimeSpan], rampLength: Double, inside: Float, outside: Float) -> [GainRamp] {
        spans.sorted { $0.start < $1.start }.flatMap { span -> [GainRamp] in
            let ramp = min(rampLength, (span.end - span.start) / 2)
            guard ramp > 0 else { return [] }
            return [
                GainRamp(span: TimeSpan(start: span.start, end: span.start + ramp), from: outside, to: inside),
                GainRamp(span: TimeSpan(start: span.end - ramp, end: span.end), from: inside, to: outside),
            ]
        }
    }
}

nonisolated struct GainRamp: Hashable, Sendable {
    let span: TimeSpan
    let from: Float
    let to: Float
}

/// A stretch of a source audio file placed on the timeline.
nonisolated struct TimelineAudioClip: Hashable, Sendable {
    let url: URL
    /// Where the clip starts in its source file.
    let sourceStart: Double
    /// Where the clip starts on the timeline.
    let start: Double
    /// Requested length; rendering also stops at the end of the source and of the timeline.
    let duration: Double
}

nonisolated enum TimelineAudioRole: Hashable, Sendable {
    /// A curated scene's music and effects.
    case background
    /// A curated scene character the learner isn't playing, at full volume throughout.
    case otherCharacter(SceneCharacter.ID)
    /// The played character's original dialogue, muted only where a kept take covers it.
    case selectedCharacterOriginal(SceneCharacter.ID)
    /// The learner's kept takes at their placements.
    case takes
    /// A raw clip's original mixed audio, which ducks under each take (approximation, not dialogue separation).
    case originalMix
    /// A raw clip's audio with the speech band filtered out, heard only under takes (approximation).
    case speechBandFiltered
}

nonisolated struct TimelineAudioLayer: Hashable, Sendable {
    let role: TimelineAudioRole
    let clips: [TimelineAudioClip]
    let gain: GainEnvelope
}

nonisolated struct TimelineVideo: Hashable, Sendable {
    let url: URL
    /// Where the timeline starts in the source video.
    let sourceStart: Double
}

/// The single description of a dub. `DubRenderer` builds the preview player item and the exported MP4 from the
/// same value, so what the learner previews is what they share.
nonisolated struct DubTimeline: Hashable, Sendable {
    let duration: Double
    let video: TimelineVideo
    let audio: [TimelineAudioLayer]
    /// How each kept take was placed, for trim, gap and overlap notices.
    let decisions: [TakeDecision]

    func layer(_ role: TimelineAudioRole) -> TimelineAudioLayer? {
        audio.first { $0.role == role }
    }

    /// A curated scene: background and every other character at full volume throughout; the played character's
    /// original dialogue everywhere no kept take covers it; and the kept takes at their lines' starts.
    /// The played character's original is muted from `suppressionPadding` before each take's line to
    /// `suppressionPadding` after the later of the line end and the take end, never reaching into that character's
    /// neighbouring lines. Nothing else is ever muted.
    static func curated(selection: CuratedSceneSelection, takes: [Int: RecordedTake], rules: DubTimingRules) -> DubTimeline {
        let scene = selection.scene
        let duration = scene.durationSeconds
        let lines = selection.scriptLines(envelopes: [:])
        let ownTakes = takes.filter { id, _ in lines.contains { $0.id == id && $0.speakerID == selection.speakerID } }
        let decisions = TakeDecision.decide(lines: lines, takes: ownTakes, boundary: .nextLineOfSameCharacter, sceneDuration: duration, rules: rules)
        let ownLines = lines.filter { $0.speakerID == selection.speakerID }
        let spans = decisions.compactMap { decision -> TimeSpan? in
            guard let line = lines.first(where: { $0.id == decision.lineID }) else { return nil }
            let previousEnd = ownLines.filter { $0.end <= line.start && $0.id != line.id }.map(\.end).max() ?? 0
            let nextStart = ownLines.filter { $0.start >= line.end && $0.id != line.id }.map(\.start).min() ?? duration
            return TimeSpan(
                start: max(previousEnd, line.start - rules.suppressionPadding, 0),
                end: min(nextStart, max(line.end, decision.end) + rules.suppressionPadding, duration)
            )
        }
        let fullScene = { (url: URL) in [TimelineAudioClip(url: url, sourceStart: 0, start: 0, duration: duration)] }
        var audio = [TimelineAudioLayer(role: .background, clips: fullScene(scene.backgroundURL), gain: .full)]
        for character in scene.characters {
            if character.id == selection.characterID {
                audio.append(TimelineAudioLayer(
                    role: .selectedCharacterOriginal(character.id),
                    clips: fullScene(character.dialogueURL),
                    gain: .muted(during: ScriptBuilder.merge(spans, joiningGap: 0), rampLength: rules.rampLength)
                ))
            } else {
                audio.append(TimelineAudioLayer(role: .otherCharacter(character.id), clips: fullScene(character.dialogueURL), gain: .full))
            }
        }
        audio.append(TimelineAudioLayer(role: .takes, clips: takeClips(decisions), gain: .full))
        return DubTimeline(duration: duration, video: TimelineVideo(url: scene.videoURL, sourceStart: 0), audio: audio, decisions: decisions)
    }

    /// A raw clip, which has no separate dialogue: under each suppression span the original mix crossfades to a copy
    /// with the speech band filtered out. This is an approximation of dialogue replacement, not separation: music
    /// in the speech band is lost under takes.
    static func filteredClip(
        source: URL,
        section: ClipSection,
        dialogueSuppressed: URL,
        placements: [TakePlacement],
        suppressionSpans: [TimeSpan],
        decisions: [TakeDecision],
        rules: DubTimingRules
    ) -> DubTimeline {
        // Spans too short for both ramps are left alone, as the original export did.
        let spans = suppressionSpans.filter { $0.end - $0.start > rules.rampLength * 2 }
        let duration = section.duration
        return DubTimeline(
            duration: duration,
            video: TimelineVideo(url: source, sourceStart: section.start),
            audio: [
                TimelineAudioLayer(
                    role: .originalMix,
                    clips: [TimelineAudioClip(url: source, sourceStart: section.start, start: 0, duration: duration)],
                    gain: .muted(during: spans, rampLength: rules.rampLength)
                ),
                TimelineAudioLayer(
                    role: .speechBandFiltered,
                    clips: [TimelineAudioClip(url: dialogueSuppressed, sourceStart: 0, start: 0, duration: duration)],
                    gain: .audible(during: spans, rampLength: rules.rampLength)
                ),
                TimelineAudioLayer(
                    role: .takes,
                    clips: placements.sorted { $0.start < $1.start }.map {
                        TimelineAudioClip(url: $0.url, sourceStart: 0, start: $0.start, duration: $0.duration)
                    },
                    gain: .full
                ),
            ],
            decisions: decisions
        )
    }

    private static func takeClips(_ decisions: [TakeDecision]) -> [TimelineAudioClip] {
        decisions.map { TimelineAudioClip(url: $0.url, sourceStart: 0, start: $0.start, duration: $0.placedSeconds) }
    }
}
