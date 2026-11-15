import Accelerate
import AVFoundation

nonisolated struct MonoAudio: Sendable {
    let samples: [Float]
    let sampleRate: Double
}

nonisolated func mediaTime(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

/// AVFoundation work for the dubbing flow, run off the main actor.
nonisolated enum MediaPipeline {
    @concurrent
    static func loadDuration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    @concurrent
    static func thumbnails(for url: URL, count: Int, maximumSize: CGSize) async throws -> [CGImage] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        let times = (0..<count).map { mediaTime(duration * (Double($0) + 0.5) / Double(count)) }
        var images: [CGImage] = []
        for await result in generator.images(for: times) {
            images.append(try result.image)
        }
        return images
    }

    /// Writes the section's audio to an M4A file for transcription and voice analysis.
    @concurrent
    static func exportAudio(from source: URL, section: ClipSection, to output: URL) async throws {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A) else {
            throw DubFlowError.exportUnavailable
        }
        session.timeRange = CMTimeRange(start: mediaTime(section.start), duration: mediaTime(section.duration))
        try prepareOutput(output)
        try await session.export(to: output, as: .m4a)
    }

    static func readMonoAudio(from url: URL) throws -> MonoAudio {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw DubFlowError.audioReadFailed(file: url.lastPathComponent, reason: "couldn't allocate a \(file.length)-frame buffer in \(format)")
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            throw DubFlowError.audioReadFailed(file: url.lastPathComponent, reason: "samples aren't 32-bit float (\(format))")
        }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: frameCount)
        for channel in 0..<channelCount {
            mono = vDSP.add(mono, UnsafeBufferPointer(start: channels[channel], count: frameCount))
        }
        return MonoAudio(samples: vDSP.divide(mono, Float(max(channelCount, 1))), sampleRate: format.sampleRate)
    }

    /// Measures each line's voice fingerprint and waveform from the section audio.
    @concurrent
    static func analyzeVoices(audioURL: URL, lines: [LineDraft], barCount: Int) async throws -> LineAnalysis {
        let audio = try readMonoAudio(from: audioURL)
        let slices = lines.map { line -> ArraySlice<Float> in
            let lower = min(audio.samples.count, max(0, Int(line.start * audio.sampleRate)))
            let upper = min(audio.samples.count, max(lower, Int(line.end * audio.sampleRate)))
            return audio.samples[lower..<upper]
        }
        return LineAnalysis(
            lines: lines,
            voicePrints: try slices.map { try VoicePrint.features(samples: Array($0), sampleRate: audio.sampleRate) },
            envelopes: slices.map { ScriptBuilder.envelope(samples: Array($0), barCount: barCount) }
        )
    }

    /// Writes a copy of `input` with the speech band (about 420–3400 Hz) filtered out.
    /// Clips don't come with separate dialogue and music tracks, so this keeps the bass and treble of the
    /// music and effects under the user's lines instead of silencing everything. It is an approximation:
    /// music in the speech band is lost too, and true separation needs prepared tracks.
    @concurrent
    static func renderDialogueSuppressed(from input: URL, to output: URL) async throws {
        let file = try AVAudioFile(forReading: input)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw DubFlowError.audioReadFailed(file: input.lastPathComponent, reason: "couldn't allocate a \(file.length)-frame buffer")
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            throw DubFlowError.audioReadFailed(file: input.lastPathComponent, reason: "samples aren't 32-bit float (\(format))")
        }
        let frameCount = Int(buffer.frameLength)
        for channel in 0..<Int(format.channelCount) {
            let samples = UnsafeMutableBufferPointer(start: channels[channel], count: frameCount)
            let filtered = try SpeechBandFilter.apply(to: Array(samples), sampleRate: format.sampleRate)
            _ = samples.update(fromContentsOf: filtered)
        }
        try prepareOutput(output)
        // Files store interleaved samples; AVAudioFile converts from the deinterleaved buffer on write.
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        try AVAudioFile(forWriting: output, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            .write(from: buffer)
    }

    /// Renders the section with the user's takes laid over it. Under each take the original audio crossfades to
    /// `dialogueSuppressed` (the same section with the speech band filtered out), so music and effects carry on.
    @concurrent
    static func exportDub(
        source: URL,
        section: ClipSection,
        dialogueSuppressed: URL,
        placements: [TakePlacement],
        suppressionSpans: [TimeSpan],
        to output: URL
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw DubFlowError.missingTrack("video")
        }
        guard let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first else {
            throw DubFlowError.missingTrack("audio")
        }

        let composition = AVMutableComposition()
        guard
            let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let original = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
            let background = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
            let voice = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw DubFlowError.exportUnavailable
        }
        let sectionRange = CMTimeRange(start: mediaTime(section.start), duration: mediaTime(section.duration))
        try video.insertTimeRange(sectionRange, of: sourceVideo, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        try original.insertTimeRange(sectionRange, of: sourceAudio, at: .zero)
        let suppressedAsset = AVURLAsset(url: dialogueSuppressed)
        guard let suppressedTrack = try await suppressedAsset.loadTracks(withMediaType: .audio).first else {
            throw DubFlowError.missingTrack("audio in \(dialogueSuppressed.lastPathComponent)")
        }
        let backgroundLength = min(section.duration, try await suppressedAsset.load(.duration).seconds)
        try background.insertTimeRange(CMTimeRange(start: .zero, duration: mediaTime(backgroundLength)), of: suppressedTrack, at: .zero)

        for placement in placements {
            let take = AVURLAsset(url: placement.url)
            guard let takeTrack = try await take.loadTracks(withMediaType: .audio).first else {
                throw DubFlowError.missingTrack("audio in \(placement.url.lastPathComponent)")
            }
            let length = min(placement.duration, try await take.load(.duration).seconds)
            try voice.insertTimeRange(CMTimeRange(start: .zero, duration: mediaTime(length)), of: takeTrack, at: mediaTime(placement.start))
        }

        // Crossfade from the full original to the dialogue-suppressed copy for each span, then back.
        let originalVolume = AVMutableAudioMixInputParameters(track: original)
        let backgroundVolume = AVMutableAudioMixInputParameters(track: background)
        backgroundVolume.setVolume(0, at: .zero)
        let ramp = 0.08
        for span in suppressionSpans where span.end - span.start > ramp * 2 {
            let fadeIn = CMTimeRange(start: mediaTime(span.start), duration: mediaTime(ramp))
            let fadeOut = CMTimeRange(start: mediaTime(span.end - ramp), duration: mediaTime(ramp))
            originalVolume.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: fadeIn)
            originalVolume.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: fadeOut)
            backgroundVolume.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: fadeIn)
            backgroundVolume.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: fadeOut)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [originalVolume, backgroundVolume]

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw DubFlowError.exportUnavailable
        }
        session.audioMix = mix
        try prepareOutput(output)
        try await session.export(to: output, as: .mp4)
    }

    /// Makes sure `url` can be written: its folder exists and any earlier file there is gone.
    static func prepareOutput(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
