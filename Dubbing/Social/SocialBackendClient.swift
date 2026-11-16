import Foundation
import os

nonisolated struct SocialOK: Decodable, Sendable { let ok: Bool }
nonisolated struct SocialInviteReceipt: Decodable, Sendable { let id: String; let code: String }

nonisolated struct SocialBackendClient: Sendable {
    let cloudURL: URL
    let siteURL: URL
    let tokens: any CoachAuthTokenProvider
    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "social-upload")

    private struct UploadFailure: LocalizedError {
        let status: Int
        let body: String
        var errorDescription: String? { "Uploading the shared dub failed (HTTP \(status)): \(body)" }
    }

    private struct EmptyArguments: Encodable {}
    private struct Call<Arguments: Encodable>: Encodable {
        let path: String
        let format: String
        let args: [Arguments]
    }
    private struct Envelope<Value: Decodable>: Decodable {
        enum Status: String, Decodable { case success, error }
        struct Failure: Decodable { let message: String }
        let status: Status
        let value: Value?
        let errorMessage: String?
        let errorData: Failure?
    }
    private struct UploadTicket: Decodable { let ticketId: String; let url: URL }
    private struct UploadedFile: Decodable { let storageId: String }

    static func configured(account: AccountModel) throws -> SocialBackendClient {
        guard let cloud = AuthConfiguration.configured(in: .main)?.convexURL,
              let site = CoachBackendClient.configuredBaseURL(in: .main) else { throw SocialError.unavailable }
        return SocialBackendClient(cloudURL: cloud, siteURL: site, tokens: AccountTokenProvider(account: account))
    }

    func requestFriend(username: String) async throws {
        struct Arguments: Encodable { let username: String }
        let _: SocialOK = try await mutate("social:requestFriend", Arguments(username: username))
    }

    func acceptFriend(id: String) async throws {
        struct Arguments: Encodable { let id: String }
        let _: SocialOK = try await mutate("social:acceptFriend", Arguments(id: id))
    }

    func removeFriend(personId: String) async throws {
        struct Arguments: Encodable { let personId: String }
        let _: SocialOK = try await mutate("social:removeFriend", Arguments(personId: personId))
    }

    func invite(assetId: String, script: SocialScript, recipientId: String?, clientId: String) async throws -> SocialInviteReceipt {
        struct Arguments: Encodable { let assetId: String; let script: SocialScript; let recipientId: String?; let clientId: String }
        return try await mutate("social:invite", Arguments(assetId: assetId, script: script, recipientId: recipientId, clientId: clientId))
    }

    func redeem(code: String) async throws -> String {
        struct Arguments: Encodable { let code: String }
        struct Receipt: Decodable { let id: String }
        let receipt: Receipt = try await mutate("social:redeem", Arguments(code: code))
        return receipt.id
    }

    func acceptInvite(id: String) async throws {
        struct Arguments: Encodable { let id: String }
        let _: SocialOK = try await mutate("social:acceptInvite", Arguments(id: id))
    }

    func closeInvite(id: String) async throws {
        struct Arguments: Encodable { let id: String }
        let _: SocialOK = try await mutate("social:closeInvite", Arguments(id: id))
    }

    func complete(id: String, assetId: String, linesRecorded: Int) async throws {
        struct Arguments: Encodable { let id: String; let assetId: String; let linesRecorded: Int }
        let _: SocialOK = try await mutate("social:complete", Arguments(id: id, assetId: assetId, linesRecorded: linesRecorded))
    }

    func postSolo(assetId: String, title: String, characterName: String, linesRecorded: Int) async throws {
        struct Arguments: Encodable { let assetId: String; let title: String; let characterName: String; let linesRecorded: Int }
        let _: SocialOK = try await mutate("social:postSolo", Arguments(assetId: assetId, title: title, characterName: characterName, linesRecorded: linesRecorded))
    }

    func approvePost(id: String) async throws {
        struct Arguments: Encodable { let id: String }
        let _: SocialOK = try await mutate("social:approvePost", Arguments(id: id))
    }

    func unpublish(id: String) async throws {
        struct Arguments: Encodable { let id: String }
        let _: SocialOK = try await mutate("social:unpublish", Arguments(id: id))
    }

    func withdrawApproval(id: String) async throws {
        struct Arguments: Encodable { let id: String }
        let _: SocialOK = try await mutate("social:withdrawApproval", Arguments(id: id))
    }

    func upload(video: URL) async throws -> String {
        let duration = try await MediaPipeline.loadDuration(of: video)
        let attributes = try video.resourceValues(forKeys: [.fileSizeKey])
        guard let size = attributes.fileSize, size > 0,
              duration.isFinite, duration > 0 else {
            throw SocialError.rejected("The shared video must be a nonempty, playable MP4.")
        }
        for attempt in 1...3 {
            let ticket: UploadTicket = try await mutate("social:prepareUpload", EmptyArguments())
            do {
                let uploaded = try await transfer(video: video, ticket: ticket)
                struct Finish: Encodable { let ticketId: String; let storageId: String }
                let _: SocialOK = try await mutate("social:finishUpload", Finish(ticketId: ticket.ticketId, storageId: uploaded.storageId))
                return ticket.ticketId
            } catch let error as UploadFailure {
                Self.logger.warning("Social upload failed. status=\(error.status) attempt=\(attempt)")
                guard attempt < 3, error.status == 408 || error.status == 429 || error.status >= 500 else { throw error }
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                Self.logger.warning("Social upload connection failed. code=\(error.code.rawValue) attempt=\(attempt)")
                guard attempt < 3 else { throw error }
            }
            try await Task.sleep(for: .milliseconds(250 * (1 << (attempt - 1))))
        }
        preconditionFailure("The upload retry loop must return or throw")
    }

    private func transfer(video: URL, ticket: UploadTicket) async throws -> UploadedFile {
        var request = URLRequest(url: ticket.url)
        request.httpMethod = "POST"
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: video)
        guard let http = response as? HTTPURLResponse else { throw SocialError.invalidResponse("The video upload returned a non-HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            let sensitive = [ticket.url.absoluteString, ticket.url.lastPathComponent] + (URLComponents(url: ticket.url, resolvingAgainstBaseURL: false)?.queryItems?.compactMap(\.value) ?? [])
            let body = sensitive.filter { !$0.isEmpty }.reduce(String(decoding: data.prefix(1000), as: UTF8.self)) { $0.replacing($1, with: "[redacted]") }
            throw UploadFailure(status: http.statusCode, body: body)
        }
        return try JSONDecoder().decode(UploadedFile.self, from: data)
    }

    func download(assetId: String) async throws -> URL {
        guard !assetId.isEmpty, assetId.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            throw SocialError.invalidResponse("The shared video identifier isn't valid.")
        }
        let request = try await authorized(URLRequest(url: siteURL.appending(path: "social/media/\(assetId)")))
        let data = try await SocialTransport.data(for: request, operation: "Downloading a shared dub")
        return try await Self.saveVideo(data)
    }

    @concurrent private static func saveVideo(_ data: Data) async throws -> URL {
        try Task.checkCancellation()
        let folder = FileManager.default.temporaryDirectory.appending(path: "CoDubs/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "shared.mp4")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    private func mutate<Arguments: Encodable, Value: Decodable>(_ name: String, _ args: Arguments) async throws -> Value {
        let body = Call(path: name, format: "convex_encoded_json", args: [args])
        let request = try await authorized(ServiceRequest.json(method: "POST", url: cloudURL.appending(path: "api/mutation"), body: body, headers: [:]))
        let data = try await SocialTransport.data(for: request, operation: name)
        let result = try JSONDecoder().decode(Envelope<Value>.self, from: data)
        switch result.status {
        case .success:
            guard let value = result.value else { throw SocialError.invalidResponse("The social service returned no result for \(name).") }
            return value
        case .error:
            guard let message = result.errorData?.message ?? result.errorMessage else { throw SocialError.invalidResponse("The social service rejected \(name) without an explanation.") }
            throw SocialError.rejected(message)
        }
    }

    private func authorized(_ request: URLRequest) async throws -> URLRequest {
        guard let token = try await tokens.convexAuthToken() else { throw SocialError.signInRequired }
        var result = request
        result.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return result
    }
}

nonisolated enum SocialTransport {
    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "social-network")

    static func data(for request: URLRequest, operation: String) async throws -> Data {
        for attempt in 1...3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw SocialError.invalidResponse("\(operation) returned a non-HTTP response.") }
                // Convex uses 560 for a completed function that threw an application error, never a transport retry.
                if (200..<300).contains(http.statusCode) || http.statusCode == 560 { return data }
                logger.warning("Social request failed. operation=\(operation, privacy: .public) status=\(http.statusCode) attempt=\(attempt)")
                if attempt < 3 && (http.statusCode == 429 || http.statusCode >= 500) {
                    try await Task.sleep(for: .milliseconds(250 * (1 << (attempt - 1))))
                    continue
                }
                let token = request.value(forHTTPHeaderField: "Authorization")?.replacing("Bearer ", with: "") ?? ""
                let body = String(decoding: data.prefix(1000), as: UTF8.self)
                let safeBody = token.isEmpty ? body : body.replacing(token, with: "[redacted]")
                throw SocialError.rejected("\(operation) failed (HTTP \(http.statusCode)): \(safeBody)")
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                logger.warning("Social connection failed. operation=\(operation, privacy: .public) code=\(error.code.rawValue) attempt=\(attempt)")
                if attempt == 3 { throw error }
                try await Task.sleep(for: .milliseconds(250 * (1 << (attempt - 1))))
            }
        }
        throw SocialError.invalidResponse("\(operation) exhausted its request attempts.")
    }
}
