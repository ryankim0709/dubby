import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// A published scene's speakers, worked out once on the backend from the whole clip: who speaks when, and each
/// character's name and best frame where the backend could tell.
nonisolated struct SceneCast: Hashable, Sendable {
    nonisolated struct Character: Hashable, Sendable, Decodable {
        let name: String?
        /// Seconds into the clip of the frame that shows this character best.
        let portraitSeconds: Double?
        /// Their face's horizontal centre in that frame, from 0 at the left edge to 1 at the right.
        let faceCenterX: Double?
    }

    /// A stretch of speech by one character, in seconds from the clip start.
    nonisolated struct Segment: Hashable, Sendable, Decodable {
        let start: Double
        let end: Double
        let character: Int
    }

    let characters: [Character]
    /// Never empty, and every segment's character is in `characters`; decoding checks both.
    let segments: [Segment]

    /// The character speaking at `seconds` into the clip; between segments, the nearest segment's.
    func character(at seconds: Double) -> Int {
        func distance(_ segment: Segment) -> Double { max(0, segment.start - seconds, seconds - segment.end) }
        guard let nearest = segments.min(by: { distance($0) < distance($1) }) else {
            preconditionFailure("A decoded cast always has segments")
        }
        return nearest.character
    }
}

nonisolated extension SceneCast: Decodable {
    private enum CodingKeys: String, CodingKey { case characters, segments }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let characters = try container.decode([Character].self, forKey: .characters)
        let segments = try container.decode([Segment].self, forKey: .segments)
        guard !segments.isEmpty, segments.allSatisfy({ characters.indices.contains($0.character) && $0.start <= $0.end }) else {
            throw DecodingError.dataCorruptedError(forKey: .segments, in: container, debugDescription: "A cast needs segments that end after they start and name listed characters")
        }
        self.init(characters: characters, segments: segments)
    }
}

/// A small still from the clip, sent so the backend's vision model can see who is on screen.
nonisolated struct SceneFrame: Encodable, Hashable, Sendable {
    let seconds: Double
    let jpegBase64: String
}

nonisolated enum SceneCastError: LocalizedError, Equatable {
    case backendNotConfigured
    case stillProcessing
    case frameEncodingFailed(seconds: Double)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            "Finding a library scene's speakers needs a backend connection in this build."
        case .stillProcessing:
            "The library scene's speakers are still being worked out. Try again shortly."
        case .frameEncodingFailed(let seconds):
            "The frame at \(seconds.preciseClockString) couldn't be encoded as JPEG."
        }
    }
}

/// Fetches a published scene's shared cast. The backend works it out once per video, from its audio and from
/// frames this client samples, and serves the stored result to every later request.
nonisolated struct SceneCastClient: Sendable {
    let baseURL: URL

    private enum Reply: Decodable {
        case ready(SceneCast)
        case processing
        case framesNeeded

        private enum CodingKeys: String, CodingKey { case status }
        private enum Status: String, Decodable { case ready, processing, framesNeeded }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Status.self, forKey: .status) {
            case .ready: self = .ready(try SceneCast(from: decoder))
            case .processing: self = .processing
            case .framesNeeded: self = .framesNeeded
            }
        }
    }

    private struct Body: Encodable {
        let slug: String
        let sha256: String
        let locale: String
        let frames: [SceneFrame]
    }

    static func configured(in bundle: Bundle) throws -> SceneCastClient {
        guard let baseURL = CoachBackendClient.configuredBaseURL(in: bundle) else {
            throw SceneCastError.backendNotConfigured
        }
        return SceneCastClient(baseURL: baseURL)
    }

    /// Asks without frames first, so a stored cast costs no upload, and samples frames only when the backend
    /// has none yet. The first request for a scene waits while the backend works, which takes up to a minute.
    @concurrent
    func cast(for clip: ImportedClip, language: SpokenLanguage) async throws -> SceneCast {
        let video = try Data(contentsOf: clip.url, options: .mappedIfSafe)
        let slug = clip.url.deletingPathExtension().lastPathComponent
        let sha256 = Data(SHA256.hash(data: video)).base64EncodedString()
        let operation = "Finding the library scene's speakers"
        var sampled: [SceneFrame] = []
        var frames: [SceneFrame] = []
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(300))
        while clock.now < deadline {
            try Task.checkCancellation()
            let body = Body(slug: slug, sha256: sha256, locale: language.identifier, frames: frames)
            var request = try ServiceRequest.json(method: "POST", url: baseURL.appending(path: "scenes/speakers"), body: body, headers: [:])
            request.timeoutInterval = 240
            switch try ServiceRequest.decode(Reply.self, from: try await ServiceRequest.data(for: request, operation: operation), operation: operation) {
            case .ready(let cast):
                return cast
            case .framesNeeded:
                if sampled.isEmpty {
                    sampled = try await Self.sampleFrames(from: clip)
                }
                frames = sampled
            case .processing:
                frames = []
                try await Task.sleep(for: .seconds(2))
            }
        }
        throw SceneCastError.stillProcessing
    }

    /// Small JPEG stills about every 1.5 seconds across the clip, and at most 80 of them: enough for the
    /// backend's vision model to see who is on screen during each line.
    @concurrent
    static func sampleFrames(from clip: ImportedClip) async throws -> [SceneFrame] {
        let interval = max(1.5, clip.durationSeconds / 80)
        let times = Array(stride(from: interval / 2, to: clip.durationSeconds, by: interval))
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        // A nearby frame decodes faster, and the backend is told when each frame was really taken.
        generator.requestedTimeToleranceBefore = mediaTime(0.25)
        generator.requestedTimeToleranceAfter = mediaTime(0.25)
        var frames: [SceneFrame] = []
        for await result in generator.images(for: times.map(mediaTime)) {
            let seconds = (try result.actualTime.seconds * 100).rounded() / 100
            frames.append(SceneFrame(seconds: seconds, jpegBase64: try jpegBase64(try result.image, seconds: seconds)))
        }
        return frames
    }

    private static func jpegBase64(_ image: CGImage, seconds: Double) throws -> String {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw SceneCastError.frameEncodingFailed(seconds: seconds)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw SceneCastError.frameEncodingFailed(seconds: seconds)
        }
        return (data as Data).base64EncodedString()
    }
}
