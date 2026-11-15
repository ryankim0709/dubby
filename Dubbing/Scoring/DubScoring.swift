import Combine
import ConvexMobile
import Foundation
import Observation
import os

/// A dub's score sheet as the backend reports it (docs/grading-contract.md, "Dub score sheet (dub-v1)").
nonisolated struct DubScoreSheet: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Sendable {
        case scoring, complete
    }

    struct Line: Decodable, Equatable, Sendable, Identifiable {
        enum Status: String, Decodable, Sendable {
            case queued, scored, unscorable, failed
        }

        struct Word: Decodable, Equatable, Sendable {
            enum TextStatus: String, Decodable, Sendable {
                case matched, substituted, omitted, inserted
            }

            let expected: String?
            let recognized: String?
            let textStatus: TextStatus
        }

        let lineIndex: Double
        let referenceText: String
        let status: Status
        let recognizedText: String?
        let lineScore: Double?
        let wordAccuracy: Double?
        let timingFit: Double?
        /// The unscorable reason or failure code.
        let reason: String?
        let coachingSummary: String?
        let words: [Word]

        var id: Double { lineIndex }
    }

    let status: Status
    let dubScore: Double?
    let wordAccuracy: Double?
    let timingFit: Double?
    let linesDubbed: Double
    let linesScored: Double
    let linesUnscorable: Double
    let linesFailed: Double
    let lines: [Line]

    var linesFinished: Int { Int(linesScored + linesUnscorable + linesFailed) }
}

nonisolated enum DubScoringError: LocalizedError, Equatable {
    case invalidUploadURL
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .invalidUploadURL: "The backend returned an upload address that isn't a URL."
        case .backend(let message): message
        }
    }
}

/// Sends finished dubs to the backend for scoring and follows each dub's score sheet. It outlives the result
/// screen, so leaving the screen doesn't stop a dub from being scored.
@Observable
final class DubScoringModel {
    enum State: Equatable {
        /// Nothing will be scored; the reason is shown to the learner.
        case notScored(String)
        case uploading
        case scoring(DubScoreSheet?)
        case complete(DubScoreSheet)
        case failed(String)
    }

    /// One dub's takes, converted to upload files while the originals are still on disk.
    private struct PreparedDub {
        struct Take {
            let lineIndex: Int
            let referenceText: String
            let startMs: Int
            let endMs: Int
            let file: URL
        }

        let clientDubID: String
        let folder: URL
        let sceneTitle: String
        let characterName: String
        let locale: String
        let timeZone: String
        let capturedAt: Date
        let takes: [Take]
        var submitted: Bool
    }

    private struct SubmitResult: Decodable {
        let dubId: String
        let created: Bool
    }

    private struct StoredFile: Decodable {
        let storageId: String
    }

    private struct BackendErrorData: Decodable {
        let message: String
    }

    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "scoring")

    private(set) var states: [UUID: State] = [:]
    private var prepared: [UUID: PreparedDub] = [:]

    /// The shared, signed-in Convex client. Only driven from the main actor.
    nonisolated(unsafe) private let client: ConvexClientWithAuth<String>

    init(client: ConvexClientWithAuth<String>) {
        self.client = client
    }

    func state(for dubID: UUID) -> State? {
        states[dubID]
    }

    /// Converts the dub's spoken takes to upload files now, then sends and follows them in the background.
    func submit(dubID: UUID, setup: DubSetup, takes: [Int: RecordedTake]) async {
        let spoken = setup.script.lines
            .sorted { $0.start < $1.start }
            .compactMap { line in takes[line.id].flatMap { $0.inputSource.isSynthetic ? nil : (line, $0) } }
        guard !spoken.isEmpty else {
            states[dubID] = .notScored("Takes recorded from practice audio aren't scored.")
            return
        }
        states[dubID] = .uploading
        do {
            let folder = URL.cachesDirectory.appending(path: "DubScoring/\(dubID.uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var files: [PreparedDub.Take] = []
            for (index, (line, take)) in spoken.enumerated() {
                let encoded = try await Self.encode(take.url, to: folder.appending(path: "line-\(index).wav"))
                files.append(PreparedDub.Take(
                    lineIndex: index,
                    referenceText: line.text,
                    startMs: Int((line.start * 1000).rounded()),
                    endMs: Int((line.end * 1000).rounded()),
                    file: encoded.url
                ))
            }
            prepared[dubID] = PreparedDub(
                clientDubID: dubID.uuidString.lowercased(),
                folder: folder,
                sceneTitle: setup.clip.title,
                characterName: setup.script.speaker(withID: setup.characterID)?.name ?? "Unnamed character",
                locale: setup.locale,
                timeZone: TimeZone.current.identifier,
                capturedAt: .now,
                takes: files,
                submitted: false
            )
        } catch {
            states[dubID] = .failed("Your takes couldn't be prepared for scoring. \(error.localizedDescription)")
            return
        }
        send(dubID)
    }

    /// Sends a dub again after a failure, skipping the upload when the backend already has it.
    func retry(dubID: UUID) {
        send(dubID)
    }

    private func send(_ dubID: UUID) {
        guard let dub = prepared[dubID] else { return }
        states[dubID] = dub.submitted ? .scoring(nil) : .uploading
        Task {
            do {
                if !dub.submitted {
                    try await upload(dub)
                    prepared[dubID]?.submitted = true
                    states[dubID] = .scoring(nil)
                }
                try await follow(dubID, clientDubID: dub.clientDubID)
            } catch {
                let message = Self.describe(error)
                Self.logger.error("Scoring a dub failed. dub=\(dubID.uuidString, privacy: .public) error=\(message, privacy: .public)")
                states[dubID] = .failed("Your dub couldn't be scored. \(message)")
            }
        }
    }

    private func upload(_ dub: PreparedDub) async throws {
        var takes: [ConvexEncodable?] = []
        for take in dub.takes {
            let uploadAddress: String = try await client.mutation("dubs:generateUploadUrl")
            guard let uploadURL = URL(string: uploadAddress) else { throw DubScoringError.invalidUploadURL }
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "POST"
            request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Data(contentsOf: take.file)
            let response = try await ServiceRequest.data(for: request, operation: "dubs.upload")
            let stored = try ServiceRequest.decode(StoredFile.self, from: response, operation: "dubs.upload")
            // Convex numbers are doubles; a Swift Int would be sent as a 64-bit integer the backend rejects.
            let encoded: [String: ConvexEncodable?] = [
                "lineIndex": Double(take.lineIndex),
                "referenceText": take.referenceText,
                "startMs": Double(take.startMs),
                "endMs": Double(take.endMs),
                "storageId": stored.storageId,
            ]
            takes.append(encoded)
        }
        let _: SubmitResult = try await client.mutation("dubs:submit", with: [
            "clientDubId": dub.clientDubID,
            "sceneTitle": dub.sceneTitle,
            "characterName": dub.characterName,
            "locale": dub.locale,
            "timeZone": dub.timeZone,
            "capturedAt": dub.capturedAt.timeIntervalSince1970 * 1000,
            "takes": takes,
        ])
    }

    /// Follows the live score sheet until every line has a result, then removes the upload files.
    private func follow(_ dubID: UUID, clientDubID: String) async throws {
        let sheets = client.subscribe(to: "dubs:scoreSheet", with: ["clientDubId": clientDubID], yielding: DubScoreSheet?.self)
        for try await sheet in sheets.values {
            guard let sheet else { continue }
            guard sheet.status == .complete else {
                states[dubID] = .scoring(sheet)
                continue
            }
            states[dubID] = .complete(sheet)
            if let folder = prepared.removeValue(forKey: dubID)?.folder {
                try FileManager.default.removeItem(at: folder)
            }
            return
        }
    }

    nonisolated private static func encode(_ source: URL, to destination: URL) async throws -> EncodedRecording {
        try await Task.detached { try AssessmentAudioEncoder.encode(from: source, to: destination) }.value
    }

    /// Backend app errors carry `{ code, message }`; other Convex errors carry their own message.
    private static func describe(_ error: Error) -> String {
        switch error {
        case ClientError.ConvexError(let data):
            guard let decoded = try? JSONDecoder().decode(BackendErrorData.self, from: Data(data.utf8)) else { return data }
            return decoded.message
        case ClientError.ServerError(let message), ClientError.InternalError(let message):
            return message
        default:
            return error.localizedDescription
        }
    }
}
