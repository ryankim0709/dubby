import AVFoundation
import AVKit
import Combine
import SwiftUI

struct ClubComposer: View {
    let account: AccountModel
    let draft: ClubMediaDraft
    let onShared: () -> Void
    @State private var caption = ""
    @State private var requestID = UUID()
    @State private var state: SendState = .ready
    @State private var attempted = false
    @Environment(\.dismiss) private var dismiss

    private enum SendState {
        case ready, sending, failed(String)
        var isSending: Bool { if case .sending = self { true } else { false } }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(draft.title).font(.title3.weight(.semibold))
                    ClubMediaPlayer(url: draft.url, kind: draft.kind)
                    TextField(draft.kind == .video ? "What did you work on?" : "Add a note (optional)", text: $caption, axis: .vertical)
                        .lineLimit(2...4)
                        .padding(12)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                        .disabled(attempted)
                        .accessibilityIdentifier("clubCaption")
                    Text("Your \(draft.kind == .video ? "video" : "voice recording") will be uploaded to Whop and shared with the two members of this demo club. Share only recordings you're comfortable letting them hear.")
                        .font(.footnote).foregroundStyle(Palette.textSecondary)
                    if case .failed(let message) = state { Text(message).foregroundStyle(Palette.streak).accessibilityIdentifier("clubShareError") }
                    Button {
                        Task { await share() }
                    } label: {
                        HStack {
                            if state.isSending { ProgressView().tint(Palette.onAccent) }
                            Text(state.isSending ? "Sharing…" : draft.kind == .video ? "Share to club" : "Send voice feedback")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(cornerRadius: 16))
                    .disabled(state.isSending || caption.count > 300)
                    .accessibilityIdentifier("clubSend")
                }
                .padding(20)
            }
            .background(Palette.background)
            .foregroundStyle(Palette.textPrimary)
            .navigationTitle(draft.kind == .video ? "Share your performance" : "Voice feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(state.isSending) } }
            .interactiveDismissDisabled(state.isSending)
        }
        .tint(Palette.accentText)
        .preferredColorScheme(.dark)
    }

    private func share() async {
        state = .sending
        attempted = true
        do {
            let client = try ClubClient.configured(account: account)
            try await client.share(draft, caption: caption, requestID: requestID)
            onShared()
            dismiss()
        } catch is CancellationError { state = .failed("Sharing was interrupted. Try again to confirm the post.") }
        catch { state = .failed(error.localizedDescription) }
    }
}

struct ClubMediaPlayer: View {
    let url: URL
    let kind: ClubMediaKind
    @State private var player: AVPlayer
    @State private var failure: String?

    init(url: URL, kind: ClubMediaKind) {
        self.url = url
        self.kind = kind
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VideoPlayer(player: player)
                .frame(minHeight: kind == .video ? 200 : 90)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel(kind == .video ? "Play club performance" : "Play voice feedback")
            if let failure { Text(failure).font(.footnote).foregroundStyle(Palette.streak) }
        }
        .onDisappear { player.pause() }
        .task(id: url) {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            do {
                guard try await AVURLAsset(url: url).load(.isPlayable) else { throw ClubError.invalidMedia("This recording couldn't be played. Refresh the club and try again.") }
                failure = nil
            } catch is CancellationError { return }
            catch { failure = error.localizedDescription }
        }
    }
}

struct ClubVoiceFeedback: View {
    let account: AccountModel
    let post: ClubPost
    let onShared: () -> Void
    @State private var recorder = TakeRecorder()
    @State private var phase: RecordingPhase = .ready
    @State private var issue: String?
    @State private var recordTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private enum RecordingPhase {
        case ready, asking, recording(URL), review(ClubMediaDraft)
        var isRecording: Bool { if case .recording = self { true } else { false } }
    }

    var body: some View {
        Group {
            if case .review(let draft) = phase {
                ClubComposer(account: account, draft: draft, onShared: { onShared(); dismiss() })
            } else {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("A helpful tip for \(post.authorName)").font(.title2.weight(.semibold))
                        Text("Say one thing that worked, then demonstrate one word or phrase they could try again.")
                            .foregroundStyle(Palette.textSecondary)
                        Label(phase.isRecording ? "Recording · up to 30 seconds" : "Up to 30 seconds. You'll review it before sending.", systemImage: "waveform")
                            .foregroundStyle(Palette.accentText)
                        if let issue { Text(issue).foregroundStyle(Palette.streak) }
                        Button {
                            if phase.isRecording { stop() } else { recordTask = Task { await record() } }
                        } label: {
                            Label(phase.isRecording ? "Stop recording" : "Record voice feedback", systemImage: phase.isRecording ? "stop.fill" : "mic.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle(cornerRadius: 16))
                        .accessibilityIdentifier("clubRecordVoice")
                        if case .asking = phase { ProgressView("Requesting microphone access…") }
                        if MicrophoneAccess(AVAudioApplication.shared.recordPermission) == .denied { OpenSettingsButton() }
                        Spacer()
                    }
                    .padding(24)
                    .background(Palette.background)
                    .foregroundStyle(Palette.textPrimary)
                    .navigationTitle("Voice feedback")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { recordTask?.cancel(); stop(); dismiss() } } }
                }
            }
        }
        .tint(Palette.accentText)
        .preferredColorScheme(.dark)
        .task(id: phase.isRecording) {
            guard phase.isRecording else { return }
            do { try await Task.sleep(for: .seconds(30)); stop() }
            catch is CancellationError { return }
            catch { issue = error.localizedDescription; stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            if phase.isRecording { stop(); issue = "Recording stopped because audio was interrupted. Review it before sending." }
        }
        .onChange(of: scenePhase) { _, next in if next != .active { stop() } }
        .onDisappear { recordTask?.cancel(); stop() }
    }

    private func record() async {
        guard case .ready = phase else { return }
        phase = .asking
        guard await AVAudioApplication.requestRecordPermission() else { phase = .ready; issue = "Allow microphone access in Settings to record feedback."; return }
        do {
            try Task.checkCancellation()
            let url = FileManager.default.temporaryDirectory.appending(path: "club-feedback-\(UUID().uuidString).m4a")
            try StudioAudioSession.activate()
            try recorder.start(writingTo: url)
            phase = .recording(url)
            issue = nil
        } catch { phase = .ready; issue = error.localizedDescription; deactivate() }
    }

    private func stop() {
        guard case .recording(let url) = phase else { return }
        do {
            let duration = try recorder.finish()
            guard duration > 0.25 else { throw ClubError.invalidMedia("Record at least a short phrase before sending feedback.") }
            phase = .review(ClubMediaDraft(url: url, kind: .voice, title: "Feedback for \(post.authorName)", replyToMessageId: post.id))
        } catch { phase = .ready; issue = error.localizedDescription }
        deactivate()
    }

    private func deactivate() {
        do { try StudioAudioSession.deactivate() }
        catch { issue = "The microphone couldn't be released: \(error.localizedDescription)" }
    }
}
