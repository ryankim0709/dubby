import AVFoundation
import Foundation

nonisolated struct ClubChallenge: Decodable, Sendable {
    let id: String
    let title: String
    let sceneId: String
    let sceneTitle: String
    let prompt: String
}

nonisolated struct ClubMember: Decodable, Identifiable, Sendable {
    let id: String
    let displayName: String
}

nonisolated enum ClubMediaKind: String, Codable, Sendable { case video, voice }

nonisolated struct ClubPost: Decodable, Identifiable, Sendable {
    let id: String
    let authorId: String
    let authorName: String
    let caption: String
    let createdAt: String
    let replyToMessageId: String?
    let kind: ClubMediaKind
    let mediaURL: URL
    let durationSeconds: Double?
}

nonisolated struct ClubFeed: Decodable, Sendable {
    let name: String
    let challenge: ClubChallenge
    let viewerId: String
    let members: [ClubMember]
    let posts: [ClubPost]

    var performances: [ClubPost] { posts.filter { $0.kind == .video } }
    func feedback(for post: ClubPost) -> [ClubPost] { posts.filter { $0.kind == .voice && $0.replyToMessageId == post.id } }
}

nonisolated struct ClubMediaDraft: Identifiable, Sendable {
    let url: URL
    let kind: ClubMediaKind
    let title: String
    let replyToMessageId: String?
    var id: URL { url }
}

nonisolated enum ClubError: LocalizedError, Sendable {
    case invalidMedia(String)

    var errorDescription: String? {
        switch self {
        case .invalidMedia(let reason): reason
        }
    }
}

/// Convex owns the Whop identities and chat credentials. The app uploads only to Whop's signed destination.
nonisolated struct ClubClient: Sendable {
    let baseURL: URL
    let tokens: any CoachAuthTokenProvider

    static func configured(account: AccountModel) throws -> ClubClient {
        guard let baseURL = CoachBackendClient.configuredBaseURL(in: .main) else { throw CoachError.backendNotConfigured }
        return ClubClient(baseURL: baseURL, tokens: AccountTokenProvider(account: account))
    }

    func feed() async throws -> ClubFeed {
        let request = URLRequest(url: baseURL.appending(path: "clubs/feed"))
        let data = try await send(request, operation: "Loading Dub Clubs")
        let feed = try ServiceRequest.decode(ClubFeed.self, from: data, operation: "Loading Dub Clubs")
        guard feed.posts.allSatisfy({ $0.mediaURL.scheme == "https" }) else { throw ClubError.invalidMedia("Whop returned an insecure media address.") }
        return feed
    }

    func share(_ draft: ClubMediaDraft, caption: String, requestID: UUID) async throws {
        struct UploadBody: Encodable { let requestId: String; let kind: ClubMediaKind; let byteSize: Int }
        struct Ticket: Decodable { let uploadId: String; let url: URL; let headers: [String: String] }
        struct PublishBody: Encodable {
            let uploadId: String
            let caption: String
            let replyToMessageId: String?
            enum CodingKeys: String, CodingKey { case uploadId, caption, replyToMessageId }
            func encode(to encoder: any Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(uploadId, forKey: .uploadId)
                try values.encode(caption, forKey: .caption)
                try values.encode(replyToMessageId, forKey: .replyToMessageId)
            }
        }
        struct Published: Decodable { let messageId: String }
        let size = try await Self.validate(draft)
        let prepare = try ServiceRequest.json(method: "POST", url: baseURL.appending(path: "clubs/uploads"), body: UploadBody(requestId: requestID.uuidString.lowercased(), kind: draft.kind, byteSize: size), headers: [:])
        let ticket = try ServiceRequest.decode(Ticket.self, from: await send(prepare, operation: "Preparing club upload"), operation: "Preparing club upload")
        guard ticket.url.scheme == "https" else { throw ClubError.invalidMedia("Whop returned an insecure upload address.") }
        var upload = URLRequest(url: ticket.url)
        upload.httpMethod = "PUT"
        // The MIME header is part of Whop's signature, including its audio/mp4a-latm value for M4A.
        for (field, value) in ticket.headers { upload.setValue(value, forHTTPHeaderField: field) }
        upload.httpBody = try await Self.mediaBytes(at: draft.url)
        _ = try await ServiceRequest.data(for: upload, operation: "Uploading your club recording")
        let publish = try ServiceRequest.json(method: "POST", url: baseURL.appending(path: "clubs/posts"), body: PublishBody(uploadId: ticket.uploadId, caption: caption, replyToMessageId: draft.replyToMessageId), headers: [:])
        let data = try await send(publish, operation: "Sharing with your club")
        _ = try ServiceRequest.decode(Published.self, from: data, operation: "Sharing with your club")
    }

    @concurrent
    static func validate(_ draft: ClubMediaDraft) async throws -> Int {
        let size = try draft.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size > 0, size <= (draft.kind == .video ? 25_000_000 : 5_000_000) else { throw ClubError.invalidMedia("Use a video under 25 MB or voice feedback under 5 MB.") }
        let asset = AVURLAsset(url: draft.url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 30.1 else { throw ClubError.invalidMedia("Club videos and voice feedback must be 30 seconds or shorter.") }
        let tracks = try await asset.loadTracks(withMediaType: draft.kind == .video ? .video : .audio)
        guard !tracks.isEmpty else { throw ClubError.invalidMedia("This file doesn't contain the expected video or voice recording.") }
        if draft.kind == .voice {
            guard try await asset.loadTracks(withMediaType: .video).isEmpty else { throw ClubError.invalidMedia("Voice feedback must be an audio recording.") }
        }
        return size
    }

    private func send(_ input: URLRequest, operation: String) async throws -> Data {
        guard let token = try await tokens.convexAuthToken() else { throw CoachError.signInRequired }
        var request = input
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await ServiceRequest.data(for: request, operation: operation)
    }

    @concurrent private static func mediaBytes(at url: URL) async throws -> Data {
        try Data(contentsOf: url)
    }
}
