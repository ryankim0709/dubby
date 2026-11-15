import AVFoundation
import os
import Speech

/// A SpeechAnalyzer module plus a way to drain its results into timed words.
nonisolated struct AnalyzerEngine: Sendable {
    let module: any SpeechModule
    let collectWords: @Sendable () async throws -> [TranscribedWord]
}

/// The transcription engine chosen for this device and language, ready to use.
nonisolated enum PreparedTranscriber: Sendable {
    /// iOS 26 SpeechAnalyzer with an installed SpeechTranscriber or DictationTranscriber model.
    case analyzer(AnalyzerEngine)
    /// The classic recognizer, for devices (and the Simulator) where Apple reports the SpeechAnalyzer models as unsupported.
    case recognizer(Locale)
}

/// Transcription with word timestamps, preferring the iOS 26 on-device SpeechAnalyzer models.
nonisolated enum SpeechTranscription {
    /// Picks the best engine this device supports, installing its model or asking for permission as needed.
    @concurrent
    static func prepare(for language: SpokenLanguage) async throws -> PreparedTranscriber {
        let requested = Locale(identifier: language.identifier)
        if let engine = await analyzerEngine(for: requested) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [engine.module]) {
                try await request.downloadAndInstall()
            }
            return .analyzer(engine)
        }
        guard await requestRecognizerAuthorization() == .authorized else { throw DubFlowError.speechRecognitionDenied }
        guard let recognizer = SFSpeechRecognizer(locale: requested), recognizer.isAvailable else {
            throw DubFlowError.unsupportedLanguage(language.name)
        }
        return .recognizer(requested)
    }

    @concurrent
    static func transcribe(audioURL: URL, using transcriber: PreparedTranscriber) async throws -> [TranscribedWord] {
        switch transcriber {
        case .analyzer(let engine):
            try await transcribeWithAnalyzer(audioURL: audioURL, engine: engine)
        case .recognizer(let locale):
            try await transcribeWithRecognizer(audioURL: audioURL, locale: locale)
        }
    }

    /// Returns a SpeechAnalyzer engine when Apple reports one as supported for this locale on this device.
    private static func analyzerEngine(for requested: Locale) async -> AnalyzerEngine? {
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            if await isUsable(transcriber) {
                return AnalyzerEngine(module: transcriber) {
                    var words: [TranscribedWord] = []
                    for try await result in transcriber.results {
                        words.append(contentsOf: Self.words(from: result.text))
                    }
                    return words
                }
            }
        }
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
            let transcriber = DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
            if await isUsable(transcriber) {
                return AnalyzerEngine(module: transcriber) {
                    var words: [TranscribedWord] = []
                    for try await result in transcriber.results {
                        words.append(contentsOf: Self.words(from: result.text))
                    }
                    return words
                }
            }
        }
        return nil
    }

    private static func isUsable(_ module: any SpeechModule) async -> Bool {
        guard await AssetInventory.status(forModules: [module]) != .unsupported else { return false }
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) != nil
    }

    private static func transcribeWithAnalyzer(audioURL: URL, engine: AnalyzerEngine) async throws -> [TranscribedWord] {
        let analyzer = SpeechAnalyzer(modules: [engine.module])
        let collector = Task { try await engine.collectWords() }
        do {
            // The analyzer only accepts its own formats (typically 16 kHz mono), so decode straight into one.
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [engine.module]) else {
                throw DubFlowError.audioReadFailed(file: audioURL.lastPathComponent, reason: "the speech model reported no compatible audio format")
            }
            let asset = AVURLAsset(url: audioURL)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw DubFlowError.missingTrack("audio")
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: format.settings)
            reader.add(output)
            guard reader.startReading() else {
                throw reader.error ?? DubFlowError.audioReadFailed(file: audioURL.lastPathComponent, reason: "the decoder couldn't start")
            }

            let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: inputs)
            while let sample = output.copyNextSampleBuffer() {
                continuation.yield(AnalyzerInput(buffer: try pcmBuffer(from: sample, format: format)))
            }
            continuation.finish()
            if reader.status == .failed {
                throw reader.error ?? DubFlowError.audioReadFailed(file: audioURL.lastPathComponent, reason: "decoding stopped partway")
            }
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            // Stop waiting on results that will never finish, then report the real failure.
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    private static func transcribeWithRecognizer(audioURL: URL, locale: Locale) async throws -> [TranscribedWord] {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw DubFlowError.unsupportedLanguage(locale.identifier)
        }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        #if targetEnvironment(simulator)
        // The Simulator claims on-device support but ships no on-device speech models, so it must use Apple's servers.
        request.requiresOnDeviceRecognition = false
        #else
        // Keep audio on the device whenever the device can recognize this language locally.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        #endif
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                let outcome: Result<[TranscribedWord], any Error>
                if let error {
                    outcome = .failure(error)
                } else if let result, result.isFinal {
                    outcome = .success(result.bestTranscription.segments.map { segment in
                        TranscribedWord(text: segment.substring, start: segment.timestamp, end: segment.timestamp + segment.duration)
                    })
                } else {
                    return
                }
                // The recognizer can report again after its final result; only the first outcome counts.
                guard resumed.withLock({ isResumed in
                    defer { isResumed = true }
                    return !isResumed
                }) else { return }
                continuation.resume(with: outcome)
            }
        }
    }

    private static func requestRecognizerAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private static func pcmBuffer(from sample: CMSampleBuffer, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw DubFlowError.audioReadFailed(file: "scene audio", reason: "couldn't allocate a \(frames)-frame buffer")
        }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else {
            throw DubFlowError.audioReadFailed(file: "scene audio", reason: "copying samples failed with OSStatus \(status)")
        }
        return buffer
    }

    /// Splits a result into timed words. Untimed pieces (usually punctuation) attach to the preceding word.
    static func words(from text: AttributedString) -> [TranscribedWord] {
        var words: [TranscribedWord] = []
        for run in text.runs {
            let piece = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] {
                words.append(TranscribedWord(text: piece, start: range.start.seconds, end: range.end.seconds))
            } else if let last = words.popLast() {
                words.append(TranscribedWord(text: last.text + piece, start: last.start, end: last.end))
            }
        }
        return words
    }
}
