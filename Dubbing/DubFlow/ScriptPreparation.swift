import Foundation

nonisolated enum ScriptSource: Hashable, Sendable {
    case voices(LineAnalysis)
    case cast(Script, SceneCast)
}

nonisolated struct PreparedScript: Hashable, Sendable {
    let request: TranscriptionRequest
    let source: ScriptSource
}

/// Full-video dialogue survives section edits, so framing never repeats transcription or cast lookup.
nonisolated enum SceneDialogue: Hashable, Sendable {
    case bundled
    case published(SceneTranscript, SceneCast)
}

enum SceneDialoguePhase: Equatable {
    case loading
    case ready(SpokenLanguage, SceneDialogue)
    case failed(FlowIssue)
}

enum ScriptPreparationPhase: Equatable {
    case preparing
    case ready(PreparedScript)
    case failed(FlowIssue)
}

nonisolated enum ScriptPreparation {
    static func dialogue(for clip: ImportedClip, language: SpokenLanguage) async throws -> SceneDialogue {
        switch clip.origin {
        case .bundled:
            return .bundled
        case .published:
            async let transcript = SceneTranscriptionClient.configured(in: .main).transcript(for: clip, language: language)
            async let cast = SceneCastClient.configured(in: .main).cast(for: clip, language: language)
            return try await .published(transcript, cast)
        }
    }

    @concurrent
    static func prepare(_ request: TranscriptionRequest, dialogue: SceneDialogue) async throws -> PreparedScript {
        try Task.checkCancellation()
        // Each cancelled framing request owns its output; a newer export must never overwrite it.
        let audioURL = request.clip.workingDirectory.appending(path: "scene-\(UUID().uuidString).m4a")
        let source: ScriptSource
        do {
            try await MediaPipeline.exportAudio(from: request.clip.url, section: request.section, to: audioURL)
            try Task.checkCancellation()
            switch dialogue {
            case .published(let transcript, let cast):
                let words = try transcript.words(for: request)
                guard !words.isEmpty else { throw DubFlowError.noSpeechFound }
                let lines = ScriptBuilder.castLines(words: words, cast: cast, sectionStart: request.section.start, pauseThreshold: 0.7, sentencePause: 0, turnPause: 0.15)
                let envelopes = try await MediaPipeline.analyzeEnvelopes(audioURL: audioURL, lines: lines.map(\.line), barCount: 48)
                source = .cast(ScriptBuilder.castScript(lines: lines, envelopes: envelopes, cast: cast), cast)
            case .bundled:
                #if targetEnvironment(simulator)
                throw SceneTranscriptionError.localClipNeedsDevice
                #else
                let transcriber = try await SpeechTranscription.prepare(for: request.sceneLanguage)
                let words = try await SpeechTranscription.transcribe(audioURL: audioURL, using: transcriber)
                try Task.checkCancellation()
                guard !words.isEmpty else { throw DubFlowError.noSpeechFound }
                let lines = ScriptBuilder.segmentLines(words: words, pauseThreshold: 0.7, sentencePause: 0)
                source = .voices(try await MediaPipeline.analyzeVoices(audioURL: audioURL, lines: lines, barCount: 48))
                #endif
            }
            try Task.checkCancellation()
        } catch {
            if FileManager.default.fileExists(atPath: audioURL.path()) {
                try FileManager.default.removeItem(at: audioURL)
            }
            throw error
        }
        try FileManager.default.removeItem(at: audioURL)
        return PreparedScript(request: request, source: source)
    }

    /// The prepared script in the language the learner dubs in. Lines keep their timing, speakers and waveforms, and
    /// a published scene's cast names go along because they're reliable; on-device voice groups are only guesses.
    static func translate(_ prepared: PreparedScript, using backend: CoachBackendClient) async throws -> PreparedScript {
        let request = prepared.request
        let source: ScriptSource
        switch prepared.source {
        case .cast(let script, let cast):
            let lines = script.lines.map { ScriptTranslationLine(speaker: script.speaker(withID: $0.speakerID)?.name, seconds: $0.duration, text: $0.text) }
            let texts = try await backend.translateScript(sceneTitle: request.clip.title, from: request.sceneLanguage, to: request.dubLanguage, lines: lines)
            source = .cast(script.replacingLineTexts(texts), cast)
        case .voices(let analysis):
            let lines = analysis.lines.map { ScriptTranslationLine(speaker: nil, seconds: $0.end - $0.start, text: $0.text) }
            let texts = try await backend.translateScript(sceneTitle: request.clip.title, from: request.sceneLanguage, to: request.dubLanguage, lines: lines)
            source = .voices(analysis.replacingLineTexts(texts))
        }
        return PreparedScript(request: request, source: source)
    }
}
