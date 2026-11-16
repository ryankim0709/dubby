import Foundation
import LiveKit
import os

/// The take coach's talking face. Simli lip-syncs only the coach's voice; it never receives the learner's take.
@MainActor
@Observable
final class TakeCoachAvatar {
    enum Phase: Equatable {
        case connecting, live, ended
    }

    private(set) var videoTrack: RemoteVideoTrack?
    private(set) var phase: Phase = .connecting
    private(set) var isSpeaking = false
    private(set) var notice: String?

    var isLive: Bool { phase == .live }

    private let backend: CoachBackendClient
    private let characterID: String
    private let room = AvatarRoom()
    private var socket: SimliAvatarSocket?
    private var speechTask: Task<Void, Never>?
    private var roomTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var utterance = 0

    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "take-coach-avatar")

    init(backend: CoachBackendClient, characterID: String) {
        self.backend = backend
        self.characterID = characterID
    }

    func run() async {
        guard phase != .ended else { return }
        do {
            let session = try await backend.takeCoachAvatarSession(characterID: characterID)
            try Task.checkCancellation()
            guard phase != .ended else { return }
            let socket = SimliAvatarSocket(transport: URLSessionSocketTransport(url: try session.socketURL()))
            self.socket = socket
            roomTask = Task { await followRoom() }
            connectionTask = Task { await enforceConnectionDeadline() }
            await socket.start()
            var closingReason: String?
            for await event in socket.events {
                guard phase != .ended else { break }
                switch event {
                case .room(let connection):
                    try await room.connect(url: connection.url, token: connection.token)
                    guard phase != .ended, !Task.isCancelled else {
                        await room.disconnect()
                        await socket.close()
                        return
                    }
                case .ready:
                    phase = .live
                    connectionTask?.cancel()
                case .speaking:
                    isSpeaking = true
                case .silent:
                    isSpeaking = false
                case .closing(let reason):
                    closingReason = reason
                case .stopped:
                    throw CoachError.providerFailed(operation: "Playing the coach video", message: closingReason ?? "Simli ended the session")
                case .closed(let reason):
                    throw CoachError.providerFailed(operation: "Playing the coach video", message: reason ?? "Simli disconnected")
                }
            }
        } catch is CancellationError {
            await end()
            return
        } catch {
            if phase != .ended { await finish(reason: error.localizedDescription) }
            return
        }
        await end()
    }

    func speak(pcm: Data) {
        guard isLive, let socket else { return }
        speechTask?.cancel()
        speechTask = Task {
            do {
                try await socket.speak(realtimePCM: pcm)
            } catch is CancellationError {
                return
            } catch {
                await finish(reason: error.localizedDescription)
            }
        }
    }

    func say(tip: String) async {
        guard phase != .ended else { return }
        let currentUtterance = utterance
        do {
            let pcm = try await backend.takeCoachSpeech(characterID: characterID, text: tip)
            try Task.checkCancellation()
            guard currentUtterance == utterance, isLive else { return }
            speak(pcm: pcm)
        } catch is CancellationError {
            return
        } catch {
            await finish(reason: error.localizedDescription)
        }
    }

    func interrupt() {
        utterance += 1
        guard isLive, let socket else { return }
        speechTask?.cancel()
        speechTask = nil
        isSpeaking = false
        Task {
            do {
                try await socket.interrupt()
            } catch {
                await finish(reason: error.localizedDescription)
            }
        }
    }

    func end() async {
        await finish(reason: nil)
    }

    private func finish(reason: String?) async {
        guard phase != .ended else { return }
        phase = .ended
        utterance += 1
        notice = reason
        isSpeaking = false
        videoTrack = nil
        speechTask?.cancel()
        connectionTask?.cancel()
        roomTask?.cancel()
        if let reason {
            Self.logger.warning("The take coach video ended. character=\(self.characterID, privacy: .public) error=\(reason, privacy: .public)")
        }
        await socket?.close()
        await room.disconnect()
    }

    private func followRoom() async {
        for await update in room.updates {
            guard phase != .ended else { return }
            switch update {
            case .videoTrack(let track):
                videoTrack = track
            case .disconnected(let reason):
                await finish(reason: reason ?? CoachError.avatarDisconnected.localizedDescription)
                return
            }
        }
    }

    private func enforceConnectionDeadline() async {
        do {
            try await Task.sleep(for: .seconds(20))
        } catch is CancellationError {
            return
        } catch {
            await finish(reason: error.localizedDescription)
            return
        }
        if phase == .connecting {
            await finish(reason: "Simli didn't connect within 20 seconds.")
        }
    }
}
