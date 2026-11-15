import CryptoKit
import Foundation
import Testing
@testable import Dubbing

struct SceneCatalogTests {
    private let video = Data("synthetic scene bytes".utf8)

    private func scene(sha256: String, byteSize: Int) -> RemoteScene {
        RemoteScene(
            slug: "synthetic-scene",
            title: "Synthetic Scene",
            durationSeconds: 3,
            video: .init(url: URL(string: "https://example.invalid/video")!, sha256: sha256, byteSize: byteSize, contentType: "video/mp4")
        )
    }

    @Test func acceptsOnlyBytesMatchingTheStoredChecksum() throws {
        let checksum = Data(SHA256.hash(data: video)).base64EncodedString()
        try SceneCatalog.verify(video, for: scene(sha256: checksum, byteSize: video.count))
        #expect(throws: SceneDownloadError.self) {
            try SceneCatalog.verify(video + Data([0]), for: scene(sha256: checksum, byteSize: video.count))
        }
    }

    @Test func cachesUnderTheChecksumWithTheSlugAsSceneID() throws {
        let checksum = Data(SHA256.hash(data: video)).base64EncodedString()
        let folder = URL(filePath: "/cache", directoryHint: .isDirectory)
        let url = try SceneCatalog.cachedFileURL(for: scene(sha256: checksum, byteSize: video.count), folder: folder)
        let hex = SHA256.hash(data: video).map { String(format: "%02x", $0) }.joined()
        #expect(url.path(percentEncoded: false) == "/cache/\(hex)/synthetic-scene.mp4")
        #expect(LibraryClip(url: url, title: "Synthetic Scene", durationSeconds: 3, origin: .published).sceneID == "synthetic-scene")
        #expect(throws: SceneDownloadError.malformedChecksum(slug: "synthetic-scene", sha256: "not/base64")) {
            try SceneCatalog.cachedFileURL(for: scene(sha256: "not/base64", byteSize: 1), folder: folder)
        }
    }
}
