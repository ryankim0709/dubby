import Foundation

/// A clip from the project's `Media/` folder, bundled into the app at build time.
nonisolated struct LibraryClip: Hashable, Sendable, Identifiable {
    let url: URL
    let title: String
    let durationSeconds: Double

    var id: URL { url }
}

nonisolated enum MediaLibrary {
    static let videoExtensions = ["mp4", "mov", "m4v"]

    /// Every bundled video, sorted by title. The clips themselves stay out of git; see `Media/README.md`.
    @concurrent
    static func loadClips(in bundle: Bundle) async throws -> [LibraryClip] {
        var clips: [LibraryClip] = []
        for url in videoExtensions.flatMap({ bundle.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }) {
            clips.append(LibraryClip(
                url: url,
                title: title(forFileName: url.deletingPathExtension().lastPathComponent),
                durationSeconds: try await MediaPipeline.loadDuration(of: url)
            ))
        }
        return sortedByTitle(clips)
    }

    static func sortedByTitle(_ clips: [LibraryClip]) -> [LibraryClip] {
        clips.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Turns a file name like `anakin-confronts-obi-wan` into `Anakin Confronts Obi Wan`.
    static func title(forFileName name: String) -> String {
        name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

extension ImportedClip {
    /// Starts a dub of a library clip, with its own working folder for audio, takes, and exports.
    nonisolated init(clip: LibraryClip) {
        self.init(
            url: clip.url,
            title: clip.title,
            durationSeconds: clip.durationSeconds,
            workingDirectory: FileManager.default.temporaryDirectory
                .appending(path: "DubProjects/\(UUID().uuidString)", directoryHint: .isDirectory)
        )
    }
}
