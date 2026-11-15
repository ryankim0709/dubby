import CryptoKit
import Foundation

/// A published scene from the backend's `GET /scenes`, with the stored video's checksum.
nonisolated struct RemoteScene: Decodable, Sendable, Equatable {
    struct Video: Decodable, Sendable, Equatable {
        let url: URL
        /// Base64 SHA-256, as Convex file storage records it.
        let sha256: String
        let byteSize: Int
        let contentType: String
    }

    let slug: String
    let title: String
    let durationSeconds: Double
    let video: Video
}

nonisolated enum SceneDownloadError: LocalizedError, Equatable {
    case unsupportedContentType(slug: String, contentType: String)
    case malformedChecksum(slug: String, sha256: String)
    case checksumMismatch(slug: String, expectedSHA256: String, actualSHA256: String, expectedBytes: Int, actualBytes: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedContentType(let slug, let contentType):
            "The scene \(slug) has a video of type \(contentType), which the app can't play."
        case .malformedChecksum(let slug, let sha256):
            "The scene \(slug) has a checksum that isn't base64 SHA-256: \(sha256)."
        case .checksumMismatch(let slug, let expectedSHA256, let actualSHA256, let expectedBytes, let actualBytes):
            "The scene \(slug) downloaded incorrectly: expected \(expectedBytes) bytes with SHA-256 \(expectedSHA256), got \(actualBytes) bytes with \(actualSHA256)."
        }
    }
}

/// Scenes stored in Convex. The dub flow reads and exports clips with AVFoundation APIs that need a
/// local file, so each video is downloaded once into Caches and reused while its checksum is unchanged.
nonisolated enum SceneCatalog {
    static var defaultFolder: URL {
        URL.cachesDirectory.appending(path: "Scenes", directoryHint: .isDirectory)
    }

    /// The published scenes, or an empty list when this build has no backend URL configured.
    static func fetch(in bundle: Bundle) async throws -> [RemoteScene] {
        guard let baseURL = CoachBackendClient.configuredBaseURL(in: bundle) else { return [] }
        struct Response: Decodable { let scenes: [RemoteScene] }
        let operation = "Loading scenes"
        let data = try await ServiceRequest.data(for: URLRequest(url: baseURL.appending(path: "scenes")), operation: operation)
        return try ServiceRequest.decode(Response.self, from: data, operation: operation).scenes
    }

    /// Downloads every scene not already cached and returns them as library clips.
    @concurrent
    static func loadClips(_ scenes: [RemoteScene], folder: URL) async throws -> [LibraryClip] {
        var clips: [LibraryClip] = []
        for scene in scenes {
            let url = try await localFile(for: scene, folder: folder)
            clips.append(LibraryClip(url: url, title: scene.title, durationSeconds: try await MediaPipeline.loadDuration(of: url), origin: .published))
        }
        return clips
    }

    /// Named after the slug so `LibraryClip.sceneID` matches it, inside a folder named for the checksum
    /// so a replaced video downloads afresh.
    static func cachedFileURL(for scene: RemoteScene, folder: URL) throws -> URL {
        let fileExtension = switch scene.video.contentType {
        case "video/mp4": "mp4"
        case "video/quicktime": "mov"
        case "video/x-m4v": "m4v"
        default: throw SceneDownloadError.unsupportedContentType(slug: scene.slug, contentType: scene.video.contentType)
        }
        guard let digest = Data(base64Encoded: scene.video.sha256), digest.count == SHA256.byteCount else {
            throw SceneDownloadError.malformedChecksum(slug: scene.slug, sha256: scene.video.sha256)
        }
        let checksumFolder = digest.map { String(format: "%02x", $0) }.joined()
        return folder
            .appending(path: checksumFolder, directoryHint: .isDirectory)
            .appending(path: "\(scene.slug).\(fileExtension)", directoryHint: .notDirectory)
    }

    static func verify(_ data: Data, for scene: RemoteScene) throws {
        let actual = Data(SHA256.hash(data: data)).base64EncodedString()
        guard actual == scene.video.sha256, data.count == scene.video.byteSize else {
            throw SceneDownloadError.checksumMismatch(
                slug: scene.slug,
                expectedSHA256: scene.video.sha256,
                actualSHA256: actual,
                expectedBytes: scene.video.byteSize,
                actualBytes: data.count
            )
        }
    }

    private static func localFile(for scene: RemoteScene, folder: URL) async throws -> URL {
        let destination = try cachedFileURL(for: scene, folder: folder)
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) { return destination }
        let data = try await ServiceRequest.data(for: URLRequest(url: scene.video.url), operation: "Downloading \(scene.title)")
        try verify(data, for: scene)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic, so an interrupted write never leaves a partial file that a later launch would trust.
        try data.write(to: destination, options: .atomic)
        return destination
    }
}
