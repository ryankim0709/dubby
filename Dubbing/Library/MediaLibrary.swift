import Foundation

/// A clip from the project's `Media/` folder, bundled into the app at build time.
nonisolated struct LibraryClip: Hashable, Sendable, Identifiable {
    let url: URL
    let title: String
    let durationSeconds: Double
    let details: LibrarySceneDetails?

    var id: URL { url }

    init(url: URL, title: String, durationSeconds: Double) {
        self.init(url: url, title: title, durationSeconds: durationSeconds, details: nil)
    }

    init(url: URL, title: String, durationSeconds: Double, details: LibrarySceneDetails?) {
        self.url = url
        self.title = title
        self.durationSeconds = durationSeconds
        self.details = details
    }

    var sceneTitle: String { title.components(separatedBy: " — ").last ?? title }
    var sourceTitle: String { title.components(separatedBy: " — ").first ?? title }
    var languageName: String? { details.map { Locale(identifier: "en").localizedString(forLanguageCode: Locale(identifier: $0.locale).language.languageCode?.identifier ?? $0.locale) ?? $0.locale } }
}

nonisolated struct LibrarySceneDetails: Codable, Hashable, Sendable {
    struct Character: Codable, Hashable, Sendable, Identifiable {
        let id: String
        let name: String
        let lineCount: Int
    }

    let locale: String
    let synopsis: String?
    let characters: [Character]
}

nonisolated struct LibrarySourceManifest: Decodable {
    struct Clip: Decodable {
        let filename: String
        let title: String
        let language: String
    }

    let clips: [Clip]
}

nonisolated enum MediaLibrary {
    static let videoExtensions = ["mp4", "mov", "m4v"]

    /// Every bundled video, sorted by title. The clips themselves stay out of git; see `Media/README.md`.
    /// Files that a curated scene's manifest references are left out: those scenes are listed from their manifests.
    @concurrent
    static func loadClips(in bundle: Bundle) async throws -> [LibraryClip] {
        let candidates = videoExtensions.flatMap { bundle.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
        let sceneFiles = CuratedSceneLoader.referencedFiles(manifestURLs: CuratedSceneLoader.manifestURLs(in: bundle))
        let sources: [LibrarySourceManifest.Clip]
        if let manifest = bundle.url(forResource: "scene-sources", withExtension: "json") {
            sources = try JSONDecoder().decode(LibrarySourceManifest.self, from: Data(contentsOf: manifest)).clips
        } else {
            sources = []
        }
        var clips: [LibraryClip] = []
        for url in rawClipURLs(candidates, excluding: sceneFiles) {
            let source = sources.first { $0.filename == url.lastPathComponent }
            clips.append(LibraryClip(
                url: url,
                title: source?.title ?? title(forFileName: url.deletingPathExtension().lastPathComponent),
                durationSeconds: try await MediaPipeline.loadDuration(of: url),
                details: source.map { LibrarySceneDetails(locale: $0.language, synopsis: nil, characters: []) }
            ))
        }
        return sortedByTitle(clips)
    }

    static func sortedByTitle(_ clips: [LibraryClip]) -> [LibraryClip] {
        clips.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The videos that aren't part of a curated scene.
    static func rawClipURLs(_ urls: [URL], excluding sceneFiles: Set<URL>) -> [URL] {
        urls.filter { !sceneFiles.contains(CuratedSceneLoader.comparable($0)) }
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
                .appending(path: "DubProjects/\(UUID().uuidString)", directoryHint: .isDirectory),
            locale: clip.details?.locale
        )
    }
}
