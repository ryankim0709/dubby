import Foundation

/// The clip being dubbed, plus the folder this dub writes its audio, takes, and exports into.
nonisolated struct ImportedClip: Hashable, Sendable {
    let url: URL
    let title: String
    let durationSeconds: Double
    let workingDirectory: URL
}

/// The part of the clip being dubbed, in seconds from the clip's start.
nonisolated struct ClipSection: Hashable, Sendable {
    let start: Double
    let end: Double

    var duration: Double { end - start }
}

nonisolated struct TimeSpan: Hashable, Sendable {
    let start: Double
    let end: Double
}

nonisolated struct SpokenLanguage: Hashable, Sendable, Identifiable {
    let identifier: String
    let name: String

    var id: String { identifier }

    static let all: [SpokenLanguage] = [
        SpokenLanguage(identifier: "en-US", name: "English"),
        SpokenLanguage(identifier: "ko-KR", name: "Korean"),
        SpokenLanguage(identifier: "ja-JP", name: "Japanese"),
        SpokenLanguage(identifier: "es-ES", name: "Spanish"),
        SpokenLanguage(identifier: "fr-FR", name: "French"),
        SpokenLanguage(identifier: "de-DE", name: "German"),
        SpokenLanguage(identifier: "zh-CN", name: "Mandarin"),
    ]
}

nonisolated struct TranscriptionRequest: Hashable, Sendable {
    let clip: ImportedClip
    let section: ClipSection
    let language: SpokenLanguage
}

/// A transcribed word, timed in seconds from the start of the section audio.
nonisolated struct TranscribedWord: Hashable, Decodable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

/// A spoken line before speakers are assigned, timed relative to the section start.
nonisolated struct LineDraft: Hashable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

/// Everything measured from the section audio that speaker grouping needs.
nonisolated struct LineAnalysis: Hashable, Sendable {
    let lines: [LineDraft]
    /// Timbre fingerprint per line; nil when the line had no clear audio.
    let voicePrints: [[Double]?]
    /// Normalized loudness bars per line, for drawing its waveform.
    let envelopes: [[Float]]
}

/// The reference identity of a curated line: what the backend, assessment and coaching know it by.
nonisolated struct LineReference: Hashable, Sendable {
    /// The manifest's `lines[].id`, stable across builds.
    let lineID: String
    let characterID: String
    /// BCP-47 language of the line, for example `en-US`.
    let locale: String
    let referenceVersion: Int
}

nonisolated struct ScriptLine: Hashable, Sendable, Identifiable {
    /// Position of the line in its script; a local index, not a backend id (see `reference`).
    let id: Int
    let text: String
    let start: Double
    let end: Double
    let speakerID: Int
    let envelope: [Float]
    /// Set for curated scene lines; nil for lines transcribed from a raw clip, which have no reference identity.
    let reference: LineReference?

    var duration: Double { end - start }

    init(id: Int, text: String, start: Double, end: Double, speakerID: Int, envelope: [Float]) {
        self.init(id: id, text: text, start: start, end: end, speakerID: speakerID, envelope: envelope, reference: nil)
    }

    init(id: Int, text: String, start: Double, end: Double, speakerID: Int, envelope: [Float], reference: LineReference?) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.speakerID = speakerID
        self.envelope = envelope
        self.reference = reference
    }

    func assigned(to speakerID: Int) -> ScriptLine {
        ScriptLine(id: id, text: text, start: start, end: end, speakerID: speakerID, envelope: envelope, reference: reference)
    }
}

nonisolated struct Speaker: Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
}

nonisolated struct Script: Hashable, Sendable {
    let lines: [ScriptLine]
    let speakers: [Speaker]

    func lines(spokenBy speakerID: Int) -> [ScriptLine] {
        lines.filter { $0.speakerID == speakerID }
    }

    func speaker(withID id: Int) -> Speaker? {
        speakers.first { $0.id == id }
    }

    func reassigning(lineID: Int, to speakerID: Int) -> Script {
        Script(lines: lines.map { $0.id == lineID ? $0.assigned(to: speakerID) : $0 }, speakers: speakers)
    }

    func renaming(speakerID: Int, to name: String) -> Script {
        Script(lines: lines, speakers: speakers.map { $0.id == speakerID ? Speaker(id: $0.id, name: name) : $0 })
    }
}

/// What the dubbing studio needs: the clip, the section, the script, and who the user plays.
nonisolated struct DubSetup: Hashable, Sendable {
    let clip: ImportedClip
    let section: ClipSection
    let script: Script
    /// The played speaker's id in `script`.
    let characterID: Int
    /// Set when the dub is of a curated scene, whose prepared tracks replace the speech-band filter.
    let curated: CuratedSceneSelection?

    /// A dub of a raw clip, scripted by transcription.
    init(clip: ImportedClip, section: ClipSection, script: Script, characterID: Int) {
        self.clip = clip
        self.section = section
        self.script = script
        self.characterID = characterID
        curated = nil
    }

    /// A dub of a curated scene; see `CuratedSceneStudio.makeSetup`.
    init(clip: ImportedClip, script: Script, curated: CuratedSceneSelection) {
        self.clip = clip
        section = ClipSection(start: 0, end: curated.scene.durationSeconds)
        self.script = script
        characterID = curated.speakerID
        self.curated = curated
    }

    /// How a take that runs long is bounded in this dub.
    var takeBoundary: TakeBoundary { curated == nil ? .nextLineOfAnyone : .nextLineOfSameCharacter }

    /// The explicit cue, line, grace and recording window for one line.
    func timing(for line: ScriptLine) -> LineTiming {
        LineTiming.make(for: line, in: script.lines, boundary: takeBoundary, sceneDuration: section.duration, rules: .standard)
    }
}

/// A finished recording of one line. The file is the learner's original take and is never modified: export reads
/// it, assessment encodes a copy from it, and a later retry writes a new file.
nonisolated struct RecordedTake: Hashable, Sendable {
    let url: URL
    let duration: Double
    /// Where the audio came from. Fixture takes are synthetic and must never be assessed.
    let inputSource: TakeInputSource

    /// A take recorded by this process's configured input (see `TakeInputSource.configured`).
    init(url: URL, duration: Double) {
        self.init(url: url, duration: duration, inputSource: TakeInputSource.configured)
    }

    init(url: URL, duration: Double, inputSource: TakeInputSource) {
        self.url = url
        self.duration = duration
        self.inputSource = inputSource
    }
}

/// Where a recorded take lands in the section, in seconds from the section start.
nonisolated struct TakePlacement: Hashable, Sendable {
    let url: URL
    let start: Double
    let duration: Double
    let lineEnd: Double
    /// Seconds cut from the end of the take so it doesn't run into the next line.
    let trimmedSeconds: Double
}

/// Timing shared by recording and export, so the studio's warnings match what the export does.
nonisolated enum DubTiming {
    /// Seconds of the scene played before a line so the user hears their cue.
    static let cueLength = 1.5
    /// Extra time a take may run past its line, for speakers who run a little long.
    static let lineGrace = 0.75
    /// Seconds the original dialogue is suppressed around each take.
    static let suppressionPadding = 0.12
    /// Cuts shorter than this are breath or room tone, not speech worth warning about.
    static let noticeableTrim = 0.15
}

enum DubFlowStep: Hashable {
    case section(ImportedClip)
    case script(TranscriptionRequest)
    case studio(DubSetup)
    case result(DubSetup, [Int: RecordedTake])
}

nonisolated enum DubFlowError: LocalizedError, Equatable {
    case unsupportedVideo
    case missingTrack(String)
    case unsupportedLanguage(String)
    case noSpeechFound
    case audioReadFailed(file: String, reason: String)
    case microphoneDenied
    case speechRecognitionDenied
    case recordingFailed(String)
    case recordingInterrupted(String)
    case playbackFailed(String)
    case exportUnavailable
    case audioFixtureMissing(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVideo:
            "That item couldn't be loaded as a video. Try an MP4 or MOV clip."
        case .missingTrack(let kind):
            "The clip has no \(kind) track."
        case .unsupportedLanguage(let identifier):
            "On-device transcription doesn't support \(identifier) yet."
        case .noSpeechFound:
            "No dialogue was found in this section. Try a section where people are talking."
        case .audioReadFailed(let file, let reason):
            "Couldn't read the audio in \(file): \(reason)."
        case .microphoneDenied:
            "Microphone access is off. Turn it on in Settings to record your lines."
        case .speechRecognitionDenied:
            "Speech recognition is off. Turn it on in Settings so DubIt can transcribe your scene."
        case .recordingFailed(let file):
            "Recording couldn't start for \(file)."
        case .recordingInterrupted(let reason):
            "Recording stopped because \(reason), so this attempt wasn't saved. Any earlier take for this line is kept."
        case .playbackFailed(let file):
            "Couldn't play \(file)."
        case .exportUnavailable:
            "This clip can't be exported on this device."
        case .audioFixtureMissing(let name):
            "The QA audio fixture \(name) isn't in this build."
        }
    }
}
