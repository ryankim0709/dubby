import AVFoundation

/// Why an exported dub can't be marked finished.
nonisolated enum DubExportError: LocalizedError, Equatable, Sendable {
    case overlappingClips(TimelineAudioRole)
    case notPlayable
    case unexpectedTracks(video: Int, audio: Int)
    case audioNotAAC
    case outOfSync(video: Double, audio: Double, expected: Double)

    var errorDescription: String? {
        switch self {
        case .overlappingClips:
            "Two takes ended up in the same place, so the dub couldn't be mixed."
        case .notPlayable:
            "The exported video can't be played."
        case .unexpectedTracks(let video, let audio):
            "The exported video has \(video) video and \(audio) audio tracks instead of one of each."
        case .audioNotAAC:
            "The exported video's sound isn't AAC."
        case .outOfSync(let video, let audio, let expected):
            String(format: "The exported picture (%.3f s) and sound (%.3f s) don't both last the scene's %.3f s.", video, audio, expected)
        }
    }
}

/// What a finished export measured, so the app marks a dub complete only after checking it.
nonisolated struct DubExportReport: Hashable, Sendable {
    let url: URL
    let expectedDuration: Double
    let videoDuration: Double
    let audioDuration: Double
    /// One video frame, the sync tolerance.
    let frameDuration: Double
}

/// Builds AVFoundation media from a `DubTimeline`. Preview and export both come from `makeComposition`, so they
/// play the same tracks with the same volume automation.
nonisolated enum DubRenderer {
    /// One composition track per timeline layer, with the layer's gain as audio-mix volume automation.
    static func makeComposition(for timeline: DubTimeline) async throws -> (AVMutableComposition, AVMutableAudioMix) {
        let composition = AVMutableComposition()
        let sourceAsset = AVURLAsset(url: timeline.video.url)
        guard let sourceVideo = try await sourceAsset.loadTracks(withMediaType: .video).first else {
            throw DubFlowError.missingTrack("video")
        }
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw DubFlowError.exportUnavailable
        }
        let videoEnd = try await sourceVideo.load(.timeRange).end.seconds
        let videoLength = min(timeline.duration, videoEnd - timeline.video.sourceStart)
        try video.insertTimeRange(
            CMTimeRange(start: mediaTime(timeline.video.sourceStart), duration: mediaTime(videoLength)),
            of: sourceVideo,
            at: .zero
        )
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)

        var parameters: [AVMutableAudioMixInputParameters] = []
        for layer in timeline.audio where !layer.clips.isEmpty {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw DubFlowError.exportUnavailable
            }
            var layerEnd = 0.0
            for clip in layer.clips.sorted(by: { $0.start < $1.start }) {
                // Inserting inside existing media would shift everything after it, so clips must not overlap.
                guard clip.start >= layerEnd - 1e-6 else { throw DubExportError.overlappingClips(layer.role) }
                let asset = AVURLAsset(url: clip.url)
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw DubFlowError.missingTrack("audio in \(clip.url.lastPathComponent)")
                }
                let available = try await asset.load(.duration).seconds - clip.sourceStart
                let length = min(clip.duration, available, timeline.duration - clip.start)
                guard length > 0 else { continue }
                try track.insertTimeRange(
                    CMTimeRange(start: mediaTime(clip.sourceStart), duration: mediaTime(length)),
                    of: source,
                    at: mediaTime(clip.start)
                )
                layerEnd = clip.start + length
            }
            let volume = AVMutableAudioMixInputParameters(track: track)
            volume.setVolume(layer.gain.initial, at: .zero)
            for ramp in layer.gain.ramps {
                volume.setVolumeRamp(
                    fromStartVolume: ramp.from,
                    toEndVolume: ramp.to,
                    timeRange: CMTimeRange(start: mediaTime(ramp.span.start), duration: mediaTime(ramp.span.end - ramp.span.start))
                )
            }
            parameters.append(volume)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return (composition, mix)
    }

    /// A player item for previewing the dub before or after export, with exactly the export's tracks and mix.
    static func makePreviewItem(for timeline: DubTimeline) async throws -> AVPlayerItem {
        let (composition, mix) = try await makeComposition(for: timeline)
        let item = AVPlayerItem(asset: composition)
        item.audioMix = mix
        return item
    }

    /// Writes the dub as an MP4: the timeline's video and one AAC track mixing every audio layer.
    /// Cancelling the task cancels the export and leaves no file behind.
    @concurrent
    static func export(_ timeline: DubTimeline, to output: URL) async throws {
        let (composition, mix) = try await makeComposition(for: timeline)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw DubFlowError.exportUnavailable
        }
        session.audioMix = mix
        try MediaPipeline.prepareOutput(output)
        do {
            try await session.export(to: output, as: .mp4)
        } catch {
            if FileManager.default.fileExists(atPath: output.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: output)
            }
            throw error
        }
    }

    /// Checks an exported dub before it's shown as finished: playable, exactly one video and one AAC audio track,
    /// and picture and sound each lasting the timeline within one video frame.
    @concurrent
    static func verifyExport(at url: URL, expectedDuration: Double) async throws -> DubExportReport {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw DubExportError.notPlayable }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let video = videoTracks.first, let audio = audioTracks.first, videoTracks.count == 1, audioTracks.count == 1 else {
            throw DubExportError.unexpectedTracks(video: videoTracks.count, audio: audioTracks.count)
        }
        let (formats, audioRange) = try await audio.load(.formatDescriptions, .timeRange)
        guard formats.contains(where: { $0.mediaSubType == .mpeg4AAC }) else { throw DubExportError.audioNotAAC }
        let (videoRange, frameRate) = try await video.load(.timeRange, .nominalFrameRate)
        let frameDuration = 1 / Double(max(frameRate, 1))
        let report = DubExportReport(
            url: url,
            expectedDuration: expectedDuration,
            videoDuration: videoRange.end.seconds,
            audioDuration: audioRange.end.seconds,
            frameDuration: frameDuration
        )
        guard
            abs(report.videoDuration - expectedDuration) <= frameDuration,
            abs(report.audioDuration - expectedDuration) <= frameDuration
        else {
            throw DubExportError.outOfSync(video: report.videoDuration, audio: report.audioDuration, expected: expectedDuration)
        }
        return report
    }
}

/// The steps from kept takes to a checked MP4, for any dub. Views show one phase per call.
nonisolated enum DubProduction {
    /// The timeline for a dub. A curated scene needs no preparation. A raw clip first gets a speech-band-filtered copy
    /// of its section, written into the dub's working folder; that is an approximation, not dialogue separation.
    @concurrent
    static func makeTimeline(setup: DubSetup, takes: [Int: RecordedTake]) async throws -> DubTimeline {
        if let curated = setup.curated {
            return DubTimeline.curated(selection: curated, takes: takes, rules: .standard)
        }
        let folder = setup.clip.workingDirectory
        let sceneAudio = folder.appending(path: "mix-scene.m4a")
        let filtered = folder.appending(path: "mix-background.caf")
        try await MediaPipeline.exportAudio(from: setup.clip.url, section: setup.section, to: sceneAudio)
        try await MediaPipeline.renderDialogueSuppressed(from: sceneAudio, to: filtered)
        let rules = DubTimingRules.standard
        let placements = ScriptBuilder.takePlacements(lines: setup.script.lines, takes: takes, sectionDuration: setup.section.duration, grace: rules.lineGrace)
        return DubTimeline.filteredClip(
            source: setup.clip.url,
            section: setup.section,
            dialogueSuppressed: filtered,
            placements: placements,
            suppressionSpans: ScriptBuilder.suppressionSpans(placements: placements, padding: rules.suppressionPadding, sectionDuration: setup.section.duration),
            decisions: TakeDecision.decide(lines: setup.script.lines, takes: takes, boundary: .nextLineOfAnyone, sceneDuration: setup.section.duration, rules: rules),
            rules: rules
        )
    }

    /// Exports the timeline and checks the result. Only a returned report means the dub is finished.
    @concurrent
    static func render(_ timeline: DubTimeline, to output: URL) async throws -> DubExportReport {
        try await DubRenderer.export(timeline, to: output)
        return try await DubRenderer.verifyExport(at: output, expectedDuration: timeline.duration)
    }
}
