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

    @concurrent
    static func thumbnail(for url: URL, at seconds: Double, maximumSize: CGSize) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        // Role stills need the dialogue frame, rather than an earlier keyframe that may be black.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: mediaTime(seconds)).image
    }

    @concurrent
    static func previewPicture(for url: URL) async throws -> VideoPicture {
        let seconds = try await loadDuration(of: url) / 2
        let frame = try await thumbnail(for: url, at: seconds, maximumSize: CGSize(width: 640, height: 640))
        return try VideoPicture(frame: frame, seconds: seconds)
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
    /// This is the raw-clip path: an approximation, not dialogue separation. It renders `DubTimeline.filteredClip`,
    /// the same timeline a preview of this dub plays.
    @concurrent
    static func exportDub(
        source: URL,
        section: ClipSection,
        dialogueSuppressed: URL,
        placements: [TakePlacement],
        suppressionSpans: [TimeSpan],
        to output: URL
    ) async throws {
        let timeline = DubTimeline.filteredClip(
            source: source,
            section: section,
            dialogueSuppressed: dialogueSuppressed,
            placements: placements,
            suppressionSpans: suppressionSpans,
            decisions: [],
            rules: .standard
        )
        try await DubRenderer.export(timeline, to: output)
    }

    /// Makes sure `url` can be written: its folder exists and any earlier file there is gone.
    static func prepareOutput(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
