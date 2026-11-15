import AVFoundation
import LiveKit
import os

/// One conversation with a coach: the learner's speech goes to the backend's coach model, and its reply goes to the avatar.
@MainActor
@Observable
final class CoachSession {
    enum Connection: Equatable {
        case connecting
        case live
        case ended(String)
    }

    let character: CoachCharacter
    let language: SpokenLanguage
    private(set) var connection: Connection = .connecting
    private(set) var activity: CoachActivity = .idle
    private(set) var turns: [CoachTurn] = []
    private(set) var videoTrack: RemoteVideoTrack?
    private(set) var errorMessage: String?
    private(set) var needsMicrophoneAccess = false
    /// The latest coach reply's feedback basis and cited evidence, for labelling that reply.
    private(set) var lastReply: CoachReply?
    /// The one exercise on show: the one the call started with, replaced by any newer one a reply carries.
    private(set) var exercise: CoachRemoteState<NextExercise>
    /// Why the coach's last reply couldn't be fetched, when the learner can try the same turn again.
    private(set) var replyFailure: CoachError?
    /// The reply text whose voice was last sent to the avatar.
    private(set) var lastSpokenText: String?

    private let backend: CoachBackendClient
    private let room = AvatarRoom()
    private let recorder = TakeRecorder()
    private var avatar: LiveAvatarClient?
    private var socket: LiveAvatarSocket?
    private var speechTask: Task<Void, Never>?
    private var transcriber: PreparedTranscriber?
    private var recordingURL: URL?
    private var turnTask: Task<Void, Never>?
    private var hasEnded = false

    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "coach")
    private static let keepAliveInterval = Duration.seconds(60)
    private static let connectTimeout = Duration.seconds(20)

    init(character: CoachCharacter, language: SpokenLanguage, backend: CoachBackendClient, exercise: CoachRemoteState<NextExercise>) {
        self.character = character
        self.language = language
        self.backend = backend
        self.exercise = exercise
    }

    /// Starts the avatar and follows the room and its socket until either ends or the caller's task is cancelled.
    func run() async {
        let socket: LiveAvatarSocket
        do {
            let token = try await backend.sessionToken(characterID: character.id, language: language)
            let avatar = LiveAvatarClient(sessionToken: token.sessionToken, sessionID: token.sessionId)
            self.avatar = avatar
            let started = try await avatar.start()
            socket = LiveAvatarSocket(transport: URLSessionSocketTransport(url: started.webSocketURL))
            self.socket = socket
            await socket.start()
            try await room.connect(to: started)
        } catch {
            connection = .ended(error.localizedDescription)
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.followRoom() }
            group.addTask { await self.followSocket(socket) }
            group.addTask { await self.keepAlive(socket) }
            group.addTask { await self.expireIfNotConnected() }
            // Either end of the call ending (or the view going away) ends the pings and the wait too.
            await group.next()
            group.cancelAll()
        }
    }

    /// Ends the session for everyone. Called when the learner leaves, so failures can only be logged.
    func end() async {
        guard !hasEnded else { return }
        hasEnded = true
        turnTask?.cancel()
        speechTask?.cancel()
        discardRecording()
        await socket?.close()
        if let avatar {
            do {
                try await avatar.stop()
            } catch {
                Self.logger.warning("Stopping the LiveAvatar session failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        await room.disconnect()
        do {
            try StudioAudioSession.deactivate()
        } catch {
            Self.logger.warning("Audio session deactivation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The single talk button: start listening, send what was said, or cut the coach off.
    func talkButtonTapped() {
        switch activity {
        case .idle: startListening()
        case .listening: finishListening()
        case .speaking: interruptCoach()
        case .transcribing, .thinking: break
        }
    }

    /// Drops a take that a call, route change, or backgrounding cut short; it isn't sent.
    func interrupt(because reason: String) {
        guard activity == .listening else { return }
        discardRecording()
        activity = .idle
        errorMessage = "Stopped listening because \(reason). Tap the mic to try again."
    }

    private func followRoom() async {
        for await update in room.updates {
            switch update {
            case .videoTrack(let track):
                videoTrack = track
            case .disconnected(let reason):
                if connection != .connecting {
                    connection = .ended(reason ?? CoachError.avatarDisconnected.localizedDescription)
                }
            }
        }
    }

    private func followSocket(_ socket: LiveAvatarSocket) async {
        for await event in socket.events {
            switch event {
            case .connected:
                if connection == .connecting { connection = .live }
            case .speakStarted:
                activity = .speaking
            case .speakEnded, .speakInterrupted:
                if activity == .speaking { activity = .idle }
            case .failed(_, let message):
                errorMessage = "The avatar reported a problem: \(message)"
            case .unreadable(let reason):
                errorMessage = "The avatar sent something the app couldn't read: \(reason)"
            case .sessionDisconnected:
                connection = .ended("The coach left the call.")
            case .closed(let reason):
                if connection != .connecting {
                    connection = .ended(reason ?? CoachError.avatarDisconnected.localizedDescription)
                }
            }
        }
    }

    /// The call is only live once the avatar's socket reports it is connected.
    private func expireIfNotConnected() async {
        guard await pause(for: Self.connectTimeout) else { return }
        if connection == .connecting {
            connection = .ended("The coach didn't pick up. Check your connection and start the call again.")
        }
    }

    private func keepAlive(_ socket: LiveAvatarSocket) async {
        while await pause(for: Self.keepAliveInterval) {
            do {
                try await socket.keepAlive()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startListening() {
        errorMessage = nil
        needsMicrophoneAccess = false
        let url = FileManager.default.temporaryDirectory.appending(path: "coach-\(UUID().uuidString).m4a")
        activity = .listening
        turnTask = Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                needsMicrophoneAccess = true
                fail(DubFlowError.microphoneDenied)
                return
            }
            do {
                try recorder.start(writingTo: url)
                recordingURL = url
            } catch {
                fail(error)
            }
        }
    }

    private func finishListening() {
        guard let url = recordingURL else { return }
        _ = recorder.stop()
        recordingURL = nil
        activity = .transcribing
        turnTask = Task {
            do {
                // The recording only exists to be transcribed; the learner's audio never leaves the phone.
                defer { removeFile(at: url) }
                let transcriber = try await preparedTranscriber()
                let words = try await SpeechTranscription.transcribe(audioURL: url, using: transcriber)
                guard let said = CoachConversation.learnerText(from: words) else { throw CoachError.noSpeechHeard }
                turns.append(CoachTurn(role: .learner, text: said))
            } catch is CancellationError {
                activity = .idle
                return
            } catch {
                fail(error)
                return
            }
            await requestReply()
        }
    }

    /// Sends the same turn again after a failed reply. The learner's words are already in `turns`.
    func retryReply() {
        guard replyFailure != nil, activity == .idle else { return }
        errorMessage = nil
        turnTask = Task { await requestReply() }
    }

    /// Asks the backend for the coach's reply to the conversation so far and hands it to the avatar.
    /// A backend failure is shown as an error the learner can retry; no reply is ever made up.
    private func requestReply() async {
        activity = .thinking
        replyFailure = nil
        let reply: CoachReply
        do {
            reply = try await backend.reply(characterID: character.id, language: language, turns: turns)
        } catch is CancellationError {
            activity = .idle
            return
        } catch {
            if let failure = error as? CoachError, failure.isRetryable || failure == .signInRequired {
                replyFailure = failure
            }
            fail(error)
            return
        }
        turns.append(CoachTurn(role: .coach, text: reply.text))
        lastReply = reply
        if let newExercise = reply.exercise { exercise = .loaded(newExercise) }
        guard let audio = reply.audio, let socket else {
            activity = .idle
            errorMessage = "The coach's voice isn't available for this reply, so it's shown as text."
            return
        }
        let pcm: Data
        do {
            pcm = try audio.pcm()
        } catch {
            fail(error)
            return
        }
        // The avatar voices exactly the reply that is shown; the socket's speak_started and
        // speak_ended events move the activity along from here.
        lastSpokenText = reply.text
        activity = .speaking
        speechTask = Task {
            do {
                try await socket.speak(pcm)
            } catch is CancellationError {
                return
            } catch {
                fail(error)
            }
        }
    }

    private func interruptCoach() {
        speechTask?.cancel()
        guard let socket else { return }
        turnTask = Task {
            do {
                try await socket.interrupt()
                activity = .idle
            } catch {
                fail(error)
            }
        }
    }

    private func preparedTranscriber() async throws -> PreparedTranscriber {
        if let transcriber { return transcriber }
        let prepared = try await SpeechTranscription.prepare(for: language)
        transcriber = prepared
        return prepared
    }

    private func fail(_ error: any Error) {
        discardRecording()
        activity = .idle
        errorMessage = error.localizedDescription
    }

    private func discardRecording() {
        guard let url = recordingURL else { return }
        _ = recorder.stop()
        recordingURL = nil
        removeFile(at: url)
    }

    private func removeFile(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Self.logger.warning("Removing a coach recording failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
