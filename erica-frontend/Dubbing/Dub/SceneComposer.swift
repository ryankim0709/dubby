import AVFoundation
import Photos

enum MediaError: Error, Equatable {
    case missingResource(String)
    case missingTrack(String)
    case playerNotReady
    case exportUnavailable
    case exportUnplayable
    case photoAccessDenied
}

enum MediaLibrary {
    /// Resolves a bundled media file. Synchronized groups usually copy resources to the bundle
    /// root, but a folder reference keeps the `Media` subdirectory, so both are checked.
    static func url(for resource: String) throws -> URL {
        let name = (resource as NSString).deletingPathExtension
        let fileExtension = (resource as NSString).pathExtension
        if let url = Bundle.main.url(forResource: name, withExtension: fileExtension)
            ?? Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "Media") {
            return url
        }
        throw MediaError.missingResource(resource)
    }
}

/// Builds the scene timeline used for listening, recording, review, and export, so what the
/// user hears while dubbing is exactly what gets rendered.
enum SceneComposer {
    /// - Parameters:
    ///   - voicing: characters whose original dialogue stems stay in the mix.
    ///   - takes: user recordings, each placed at the scene time it was captured.
    static func composition(for scene: SceneClip, voicing: Set<String>, takes: [Take]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        let sceneDuration = CMTime(seconds: scene.duration, preferredTimescale: 600)

        let videoAsset = AVURLAsset(url: try MediaLibrary.url(for: scene.media.video))
        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw MediaError.missingTrack(scene.media.video)
        }
        let videoRange = try await sourceVideo.load(.timeRange)
        try videoTrack.insertTimeRange(
            CMTimeRange(start: videoRange.start, duration: CMTimeMinimum(videoRange.duration, sceneDuration)),
            of: sourceVideo,
            at: .zero
        )
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)

        var beds = [try MediaLibrary.url(for: scene.media.bed)]
        for character in scene.characters where voicing.contains(character.id) {
            guard let stem = scene.media.stems[character.id] else {
                throw MediaError.missingResource("stem for \(character.id)")
            }
            beds.append(try MediaLibrary.url(for: stem))
        }
        for url in beds {
            try await insertAudio(from: url, at: .zero, into: composition, sceneDuration: sceneDuration)
        }
        for take in takes {
            let start = CMTime(seconds: take.sceneStart, preferredTimescale: 600)
            try await insertAudio(from: take.fileURL, at: start, into: composition, sceneDuration: sceneDuration)
        }
        return composition
    }

    /// Each source gets its own track so overlapping dialogue mixes instead of replacing.
    /// Takes are captured inside the scene window, so the clamp to the scene end only trims
    /// trailing silence, never shifts the timeline.
    private static func insertAudio(from url: URL, at start: CMTime, into composition: AVMutableComposition, sceneDuration: CMTime) async throws {
        let available = CMTimeSubtract(sceneDuration, start)
        guard available > .zero else { return }
        let asset = AVURLAsset(url: url)
        guard let source = try await asset.loadTracks(withMediaType: .audio).first,
              let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw MediaError.missingTrack(url.lastPathComponent)
        }
        let sourceRange = try await source.load(.timeRange)
        let duration = CMTimeMinimum(sourceRange.duration, available)
        try track.insertTimeRange(CMTimeRange(start: sourceRange.start, duration: duration), of: source, at: start)
    }
}

enum DubExporter {
    /// Renders the dub to an MP4 and confirms the file is playable with audio before returning it.
    static func render(_ summary: DubSummary) async throws -> URL {
        let voicing = Set(summary.scene.characters.map(\.id)).subtracting([summary.characterID])
        let composition = try await SceneComposer.composition(for: summary.scene, voicing: voicing, takes: summary.takes)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaError.exportUnavailable
        }
        let url = URL.temporaryDirectory.appending(path: "Dubby-\(summary.scene.id)-\(UUID().uuidString).mp4")
        try await session.export(to: url, as: .mp4)

        let exported = AVURLAsset(url: url)
        let isPlayable = try await exported.load(.isPlayable)
        let audioTracks = try await exported.loadTracks(withMediaType: .audio)
        guard isPlayable, !audioTracks.isEmpty else {
            throw MediaError.exportUnplayable
        }
        return url
    }
}

enum PhotoLibrary {
    static func saveVideo(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw MediaError.photoAccessDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
