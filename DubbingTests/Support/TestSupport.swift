import Foundation

/// Loads files from `DubbingTests/Fixtures`, which Xcode copies into the test bundle.
/// Fixtures must be synthetic or properly licensed; never add personal recordings.
enum TestFixtures {
    /// 3 s of black 64×64 H.264 video with 80 Hz and 1 kHz tones.
    static func twoToneVideo() throws -> URL {
        try url(named: "two-tone-3s", extension: "mp4")
    }

    static func url(named name: String, extension fileExtension: String) throws -> URL {
        guard let url = Bundle(for: BundleAnchor.self).url(forResource: name, withExtension: fileExtension) else {
            throw TestFixtureError.missing("\(name).\(fileExtension)")
        }
        return url
    }
}

/// Thrown instead of using `#require`, which records a test issue even when the caller expects the throw.
/// A test that lets it propagate still fails, and its message names the missing file.
struct TestFixtureError: Error, CustomStringConvertible, Equatable {
    let fileName: String

    static func missing(_ fileName: String) -> TestFixtureError {
        TestFixtureError(fileName: fileName)
    }

    var description: String {
        "Missing fixture \(fileName) in the DubbingTests bundle; add it under DubbingTests/Fixtures."
    }
}

/// A scratch folder that is deleted when the test releases it, so tests leave nothing behind.
final class TemporaryDirectory {
    let url: URL

    init(prefix: String = "DubbingTests") throws {
        url = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func appending(path: String) -> URL {
        url.appending(path: path)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Anchors `Bundle(for:)` to the test bundle.
private final class BundleAnchor {}
