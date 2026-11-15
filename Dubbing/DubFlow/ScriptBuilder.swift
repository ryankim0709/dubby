import Accelerate
import Foundation

/// Pure steps that turn transcribed words and line audio into a dub script and a dub mix plan.
nonisolated enum ScriptBuilder {
    /// Splits timed words into lines at long pauses, or at shorter pauses after sentence-ending punctuation.
    static func segmentLines(words: [TranscribedWord], pauseThreshold: Double, sentencePause: Double) -> [LineDraft] {
        var lines: [LineDraft] = []
        var current: [TranscribedWord] = []
        for word in words.sorted(by: { $0.start < $1.start }) {
            if let previous = current.last {
                let gap = word.start - previous.end
                let endsSentence = previous.text.last.map { ".?!".contains($0) } ?? false
                if gap >= pauseThreshold || (endsSentence && gap >= sentencePause), let line = draft(from: current) {
                    lines.append(line)
                    current = []
                }
            }
            current.append(word)
        }
        if let line = draft(from: current) {
            lines.append(line)
        }
        return lines
    }

    private static func draft(from words: [TranscribedWord]) -> LineDraft? {
        guard let first = words.first, let last = words.last else { return nil }
        return LineDraft(text: words.map(\.text).joined(separator: " "), start: first.start, end: last.end)
    }

    /// Builds the editable script, naming speakers from `names` where given.
    static func buildScript(analysis: LineAnalysis, speakerCount: Int, names: [String]) -> Script {
        let assignments = VoicePrint.clusterSpeakers(prints: analysis.voicePrints, speakerCount: speakerCount)
        let lines = analysis.lines.indices.map { index in
            ScriptLine(
                id: index,
                text: analysis.lines[index].text,
                start: analysis.lines[index].start,
                end: analysis.lines[index].end,
                speakerID: assignments[index],
                envelope: analysis.envelopes[index]
            )
        }
        let speakers = (0..<max(speakerCount, 1)).map { id in
            Speaker(id: id, name: id < names.count ? names[id] : "Speaker \(id + 1)")
        }
        return Script(lines: lines, speakers: speakers)
    }

    /// Splits section words into lines like `segmentLines`, and also where a word after a pause of `turnPause`
    /// or more belongs to someone other than the line's main speaker so far, so a quick reply gets its own line.
    /// Each line goes to whoever speaks most of it, which absorbs a word whose timing straddles a speaker change.
    static func castLines(
        words: [TranscribedWord],
        cast: SceneCast,
        sectionStart: Double,
        pauseThreshold: Double,
        sentencePause: Double,
        turnPause: Double
    ) -> [CastLine] {
        let sorted = words.sorted { $0.start < $1.start }
        let speakers = sorted.map { cast.character(at: sectionStart + ($0.start + $0.end) / 2) }
        func mainSpeaker(of group: [Int]) -> Int? {
            let spoken = Dictionary(group.map { (speakers[$0], sorted[$0].end - sorted[$0].start) }, uniquingKeysWith: +)
            // Ties go to the lower id, so the result doesn't depend on dictionary order.
            return spoken.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
        }
        var groups: [[Int]] = []
        for index in sorted.indices {
            if let group = groups.last, let previousIndex = group.last {
                let previous = sorted[previousIndex]
                let gap = sorted[index].start - previous.end
                let endsSentence = previous.text.last.map { ".?!".contains($0) } ?? false
                let changesSpeaker = gap >= turnPause && speakers[index] != mainSpeaker(of: group)
                if !(gap >= pauseThreshold || (endsSentence && gap >= sentencePause) || changesSpeaker) {
                    groups[groups.count - 1].append(index)
                    continue
                }
            }
            groups.append([index])
        }
        return groups.compactMap { group in
            guard let line = draft(from: group.map { sorted[$0] }), let character = mainSpeaker(of: group) else { return nil }
            return CastLine(line: line, character: character)
        }
    }

    /// The editable script for cast lines. Every cast character is a speaker, named when the backend could tell.
    static func castScript(lines: [CastLine], envelopes: [[Float]], cast: SceneCast) -> Script {
        Script(
            lines: lines.indices.map { index in
                ScriptLine(
                    id: index,
                    text: lines[index].line.text,
                    start: lines[index].line.start,
                    end: lines[index].line.end,
                    speakerID: lines[index].character,
                    envelope: envelopes[index]
                )
            },
            speakers: cast.characters.indices.map { Speaker(id: $0, name: cast.characters[$0].name ?? "Speaker \($0 + 1)") }
        )
    }

    /// Loudness bars normalized to the loudest bar.
    static func envelope(samples: [Float], barCount: Int) -> [Float] {
        guard barCount > 0, samples.count >= barCount else { return Array(repeating: 0, count: max(barCount, 0)) }
        let size = samples.count / barCount
        let levels = (0..<barCount).map { vDSP.rootMeanSquare(samples[($0 * size)..<(($0 + 1) * size)]) }
        let peak = levels.max() ?? 0
        return peak > 0 ? levels.map { $0 / peak } : levels
    }

    /// How long a take for `line` may run: up to `grace` past the line, but never into the next line or past the scene.
    static func allowedTakeDuration(for line: ScriptLine, in lines: [ScriptLine], sectionDuration: Double, grace: Double) -> Double {
        let nextStart = lines.filter { $0.start > line.start }.map(\.start).min() ?? sectionDuration
        return max(0, min(line.end + grace, nextStart, sectionDuration) - line.start)
    }

    /// Places each recorded take at its line's start, cut to its allowed duration.
    /// The cut is recorded on the placement so the app can tell the user instead of trimming silently.
    static func takePlacements(lines: [ScriptLine], takes: [Int: RecordedTake], sectionDuration: Double, grace: Double) -> [TakePlacement] {
        lines.sorted { $0.start < $1.start }.compactMap { line in
            guard let take = takes[line.id] else { return nil }
            let allowed = allowedTakeDuration(for: line, in: lines, sectionDuration: sectionDuration, grace: grace)
            let duration = min(take.duration, allowed)
            guard duration > 0 else { return nil }
            return TakePlacement(url: take.url, start: line.start, duration: duration, lineEnd: line.end, trimmedSeconds: take.duration - duration)
        }
    }

    /// Spans where the original dialogue is suppressed so the actor's voice doesn't play under the user's take.
    static func suppressionSpans(placements: [TakePlacement], padding: Double, sectionDuration: Double) -> [TimeSpan] {
        let spans = placements.map { placement in
            TimeSpan(
                start: max(0, placement.start - padding),
                end: min(sectionDuration, max(placement.lineEnd, placement.start + placement.duration) + padding)
            )
        }
        return merge(spans, joiningGap: padding * 2)
    }

    /// Merges spans that overlap or sit closer than `joiningGap`, so volume ramps never overlap.
    static func merge(_ spans: [TimeSpan], joiningGap: Double) -> [TimeSpan] {
        spans.sorted { $0.start < $1.start }.reduce(into: []) { merged, span in
            if let last = merged.last, span.start - last.end <= joiningGap {
                merged[merged.count - 1] = TimeSpan(start: last.start, end: max(last.end, span.end))
            } else {
                merged.append(span)
            }
        }
    }
}

nonisolated enum SectionHandle {
    case start
    case end
    case move
}

/// Pure math for dragging the section selection on the timeline.
nonisolated enum SectionEditing {
    static let minimumLength = 2.0
    static let maximumLength = 30.0
    static let defaultLength = 20.0

    static func adjusted(origin: TimeSpan, handle: SectionHandle, delta: Double, clipDuration: Double) -> TimeSpan {
        let maximum = min(maximumLength, clipDuration)
        switch handle {
        case .start:
            let start = clamp(origin.start + delta, lower: max(0, origin.end - maximum), upper: origin.end - minimumLength)
            return TimeSpan(start: start, end: origin.end)
        case .end:
            let end = clamp(origin.end + delta, lower: origin.start + minimumLength, upper: min(clipDuration, origin.start + maximum))
            return TimeSpan(start: origin.start, end: end)
        case .move:
            let length = origin.end - origin.start
            let start = clamp(origin.start + delta, lower: 0, upper: clipDuration - length)
            return TimeSpan(start: start, end: start + length)
        }
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}

extension Double {
    /// Formats seconds as `m:ss.s`.
    nonisolated var preciseClockString: String {
        let tenths = Int((self * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}
