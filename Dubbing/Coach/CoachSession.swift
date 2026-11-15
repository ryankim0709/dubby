import AVFoundation
import LiveKit
import os

/// One conversation with a coach: the learner's speech goes to the LLM, and the LLM's reply goes to the avatar.
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

    private let practice: CoachPracticeContext?
    private let backend: CoachBackendClient
    private let room = AvatarRoom()
    private let recorder = TakeRecorder()
    private var avatar: LiveAvatarClient?
    private var transcriber: PreparedTranscriber?
    private var recordingURL: URL?
    private var turnTask: Task<Void, Never>?
    private var hasEnded = false

    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "coach")
    private static let keepAliveInterval = Duration.seconds(60)

    init(character: CoachCharacter, language: SpokenLanguage, backend: CoachBackendClient, practice: CoachPracticeContext?, exercise: CoachRemoteState<NextExercise>) {
        self.character = character
        self.language = language
        self.backend = backend
        self.practice = practice
        self.exercise = exercise
    }

    /// Starts the avatar and follows the room until it disconnects or the caller's task is cancelled.
    func run() async {
        do {
            let token = try await backend.sessionToken(characterID: character.id, language: language)
            let avatar = LiveAvatarClient(sessionToken: token.sessionToken)
            self.avatar = avatar
            try await room.connect(to: try await avatar.start())
            connection = .live
        } catch {
            connection = .ended(error.localizedDescription)
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.followRoom() }
            group.addTask { await self.keepAlive() }
            // The room ending (or the view going away) ends the keep-alive pings too.
            await group.next()
            group.cancelAll()
        }
    }

    /// Ends the session for everyone. Called when the learner leaves, so failures can only be logged.
    func end() async {
        guard !hasEnded else { return }
        hasEnded = true
        turnTask?.cancel()
        discardRecording()
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
            case .event(.avatarStartedSpeaking):
                activity = .speaking
            case .event(.avatarStoppedSpeaking):
                if activity == .speaking { activity = .idle }
            case .event(.sessionStopped(let reason)):
                connection = .ended("The coach left the call (\(reason)).")
            case .unreadableEvent(let reason):
                errorMessage = "The coach sent something the app couldn't read: \(reason)"
            case .disconnected(let reason):
                if case .live = connection {
                    connection = .ended(reason ?? CoachError.avatarDisconnected.localizedDescription)
                }
            }
        }
    }

    private func keepAlive() async {
        while await pause(for: Self.keepAliveInterval) {
            guard let avatar else { return }
            do {
                try await avatar.keepAlive()
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
                activity = .thinking
                let reply = try await backend.reply(characterID: character.id, language: language, practice: practice, turns: turns)
                turns.append(CoachTurn(role: .coach, text: reply.text))
                lastReply = reply
                if let newExercise = reply.exercise { exercise = .loaded(newExercise) }
                // The avatar says the reply exactly as it is shown.
                try await room.speak(reply.text)
                // The avatar's speak_started and speak_ended events move this along from here.
                activity = .speaking
            } catch is CancellationError {
                activity = .idle
            } catch {
                fail(error)
            }
        }
    }

    private func interruptCoach() {
        turnTask = Task {
            do {
                try await room.interrupt()
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
