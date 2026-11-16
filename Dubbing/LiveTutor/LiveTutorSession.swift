import AVFoundation
import os

/// One live call with the pronunciation tutor about a scored dub. The backend writes the tutor's brief from the
/// dub's stored score sheet; the learner's voice goes straight to OpenAI's Realtime API and the tutor answers aloud.
@MainActor
@Observable
final class LiveTutorSession {
    enum Activity: Equatable {
        /// The microphone is open and nobody is speaking, including while the tutor works out its reply.
        case listening
        case learnerSpeaking
        case tutorSpeaking
    }

    enum Phase: Equatable {
        case connecting
        case live(Activity)
        case ended(reason: String?)
    }

    private(set) var phase: Phase = .connecting
    private(set) var transcript = LiveTutorTranscript.empty
    /// A problem the service reported that didn't end the call.
    private(set) var notice: String?
    private(set) var needsMicrophoneAccess = false

    private let clientDubID: String
    private let backend: CoachBackendClient
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private var audio: LiveTutorAudio?
    private var transport: URLSessionSocketTransport?
    private var timeline = TutorPlaybackTimeline.idle
    private var microphoneTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var hasEnded = false

    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "live-tutor")

    init(clientDubID: String, backend: CoachBackendClient) {
        self.clientDubID = clientDubID
        self.backend = backend
        startedAt = clock.now
    }

    /// Connects and follows the call until it ends or the caller's task is cancelled.
    func run() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            needsMicrophoneAccess = true
            phase = .ended(reason: "Dubby needs microphone access to talk with your tutor. Turn it on in Settings.")
            return
        }
        do {
            let grant = try await backend.liveTutorSession(clientDubID: clientDubID)
            let transport = URLSessionSocketTransport(
                url: try LiveTutorRealtime.socketURL(model: grant.model),
                protocols: LiveTutorRealtime.subprotocols(clientSecret: grant.clientSecret)
            )
            self.transport = transport
            // The learner may have left while the key was on its way; an open socket would keep a paid session running.
            guard !hasEnded else {
                await transport.close()
                return
            }
            await follow(transport)
            await end()
        } catch is CancellationError {
            return
        } catch {
            finish(reason: error.localizedDescription)
        }
    }

    /// Ends the call. Called when the learner leaves, so failures can only be logged.
    func end() async {
        guard !hasEnded else { return }
        hasEnded = true
        microphoneTask?.cancel()
        settleTask?.cancel()
        await transport?.close()
        do {
            try audio?.stop()
        } catch {
            Self.logger.warning("Stopping the tutor's audio failed. error=\(error.localizedDescription, privacy: .public)")
        }
        if case .ended = phase { return }
        phase = .ended(reason: nil)
    }

    /// Stops the call when a phone call, another app, or backgrounding takes the audio away.
    func interrupt(because reason: String) {
        guard case .live = phase else { return }
        finish(reason: "The call stopped because \(reason). Start it again to keep practising.")
    }

    private func finish(reason: String) {
        guard !hasEnded else { return }
        phase = .ended(reason: reason)
        Task { await end() }
    }

    private func follow(_ transport: URLSessionSocketTransport) async {
        while !Task.isCancelled && !hasEnded {
            let frame: String
            do {
                frame = try await transport.receive()
            } catch {
                finish(reason: "The connection to your tutor closed. \(error.localizedDescription)")
                return
            }
            do {
                guard let event = try LiveTutorServerEvent.decode(frame) else { continue }
                try await handle(event, on: transport)
            } catch {
                finish(reason: error.localizedDescription)
                return
            }
        }
    }

    private func handle(_ event: LiveTutorServerEvent, on transport: URLSessionSocketTransport) async throws {
        // A frame received just before the call ended must not reopen the microphone.
        guard !hasEnded else { return }
        transcript = transcript.applying(event)
        switch event {
        case .sessionCreated:
            try startAudio(sendingTo: transport)
            phase = .live(.listening)
            try await transport.send(LiveTutorClientEvent.createResponse())
        case .learnerStartedSpeaking:
            try await cutInIfTutorIsSpeaking(on: transport)
            phase = .live(.learnerSpeaking)
        case .learnerStoppedSpeaking:
            phase = .live(.listening)
        case .tutorAudio(_, let itemID, let contentIndex, let pcm):
            let samples = LiveTutorRealtime.samples(fromPCM16: pcm)
            try audio?.play(samples)
            timeline = timeline.scheduling(itemID: itemID, contentIndex: contentIndex, frames: samples.count, at: elapsed)
            settleTask?.cancel()
            phase = .live(.tutorSpeaking)
        case .responseDone:
            settleAfterPlayback()
        case .responseFailed(_, let message):
            notice = message
            settleAfterPlayback()
        case .failed(let code, let message):
            // Errors such as cancelling a reply that already finished don't end the session; a fatal one closes the socket.
            Self.logger.warning("The Realtime API reported an error. code=\(code ?? "none", privacy: .public)")
            notice = message
        case .learnerTranscript, .learnerTranscriptUnavailable, .tutorTranscript, .responseCreated, .toolCall:
            break
        }
    }

    private var elapsed: Duration { clock.now - startedAt }

    private func startAudio(sendingTo transport: URLSessionSocketTransport) throws {
        let audio = try LiveTutorAudio()
        self.audio = audio
        let encoder = try LiveTutorMicrophoneEncoder(inputSampleRate: try audio.start())
        microphoneTask = Task {
            for await samples in audio.microphone {
                do {
                    let pcm = try encoder.encode(samples)
                    guard !pcm.isEmpty else { continue }
                    try await transport.send(LiveTutorClientEvent.appendAudio(pcm))
                } catch is CancellationError {
                    return
                } catch {
                    finish(reason: error.localizedDescription)
                    return
                }
            }
        }
    }

    /// The server stops generating when the learner cuts in; the app stops what's queued and reports how much was heard.
    private func cutInIfTutorIsSpeaking(on transport: URLSessionSocketTransport) async throws {
        settleTask?.cancel()
        guard let current = timeline.current, let heardMs = timeline.heardMilliseconds(at: elapsed) else { return }
        audio?.stopPlayback()
        timeline = .idle
        try await transport.send(LiveTutorClientEvent.truncate(itemID: current.id, contentIndex: current.contentIndex, audioEndMs: heardMs))
    }

    /// The reply is complete on the server before it finishes playing here, so the tutor counts as speaking until then.
    private func settleAfterPlayback() {
        let remaining = timeline.remaining(at: elapsed)
        settleTask?.cancel()
        settleTask = Task {
            do {
                try await clock.sleep(for: remaining)
            } catch {
                return
            }
            if phase == .live(.tutorSpeaking) { phase = .live(.listening) }
        }
    }
}
