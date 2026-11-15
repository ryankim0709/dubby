import Foundation
import Testing

struct TestSupportTests {
    @Test func loadsTheSyntheticFixtureFromTheTestBundle() throws {
        let url = try TestFixtures.twoToneVideo()
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int)
        #expect(size > 0)
    }

    @Test func reportsAMissingFixtureAsAFailure() {
        #expect(throws: (any Error).self) { try TestFixtures.url(named: "does-not-exist", extension: "mp4") }
    }

    @Test func removesTheScratchFolderWhenReleased() throws {
        var folder: TemporaryDirectory? = try TemporaryDirectory()
        let url = try #require(folder?.url)
        let file = url.appending(path: "note.txt")
        try Data("x".utf8).write(to: file)
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        folder = nil
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }
}
