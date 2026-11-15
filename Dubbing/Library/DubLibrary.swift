import Foundation

/// A finished dub the user exported, stored on the device.
nonisolated struct SavedDub: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let sceneTitle: String
    let characterName: String
    let linesDubbed: Int
    let totalLines: Int
    let sceneSeconds: Double
    let createdAt: Date
    let videoFileName: String
    /// Measured take data. Nil for dubs saved before takes were measured, which the UI reports as not measured.
    var takeMeasurements: [TakeMeasurement]? = nil
}

/// Saved dubs live in one folder: each video plus a `dubs.json` index, newest first.
nonisolated enum DubLibrary {
    static var defaultFolder: URL {
        URL.documentsDirectory.appending(path: "Dubs", directoryHint: .isDirectory)
    }

    static func load(from folder: URL) throws -> [SavedDub] {
        let index = indexURL(in: folder)
        // No index yet just means nothing has been saved.
        guard FileManager.default.fileExists(atPath: index.path(percentEncoded: false)) else { return [] }
        return try decoder.decode([SavedDub].self, from: Data(contentsOf: index))
    }

    /// Copies the exported video into the library and records it. Returns the updated list.
    static func save(video: URL, as dub: SavedDub, in folder: URL) throws -> [SavedDub] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: video, to: videoURL(for: dub, in: folder))
        let dubs = [dub] + (try load(from: folder))
        try encoder.encode(dubs).write(to: indexURL(in: folder), options: .atomic)
        return dubs
    }

    /// Removes a dub's video and its index entry. Returns the remaining dubs.
    static func delete(_ dub: SavedDub, in folder: URL) throws -> [SavedDub] {
        let remaining = try load(from: folder).filter { $0.id != dub.id }
        try encoder.encode(remaining).write(to: indexURL(in: folder), options: .atomic)
        let video = videoURL(for: dub, in: folder)
        if FileManager.default.fileExists(atPath: video.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: video)
        }
        return remaining
    }

    static func videoURL(for dub: SavedDub, in folder: URL) -> URL {
        folder.appending(path: dub.videoFileName)
    }

    private static func indexURL(in folder: URL) -> URL {
        folder.appending(path: "dubs.json")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
