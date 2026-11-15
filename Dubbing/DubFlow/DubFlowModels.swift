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
nonisolated struct TranscribedWord: Hashable, Sendable {
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

nonisolated struct ScriptLine: Hashable, Sendable, Identifiable {
    let id: Int
    let text: String
    let start: Double
    let end: Double
    let speakerID: Int
    let envelope: [Float]

    var duration: Double { end - start }

    func assigned(to speakerID: Int) -> ScriptLine {
        ScriptLine(id: id, text: text, start: start, end: end, speakerID: speakerID, envelope: envelope)
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
    let characterID: Int
}

nonisolated struct RecordedTake: Hashable, Sendable {
    let url: URL
    let duration: Double
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
        }
    }
}
