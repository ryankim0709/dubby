import AVFoundation
import SwiftUI

/// A spoken practice call about one scored dub: the tutor takes the learner through the lines they missed.
struct LiveTutorView: View {
    @State private var session: LiveTutorSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(session: LiveTutorSession) {
        _session = State(initialValue: session)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BackHeader(title: "Practise with your tutor") {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Close tutor")
                    .accessibilityIdentifier("closeLiveTutor")
                }
                    .padding(.top, 8)
                status
                ForEach(session.transcript.lines) { line in
                    TranscriptLine(line: line)
                }
                if let notice = session.notice {
                    Text(notice)
                        .dubFont(14, weight: .regular)
                        .foregroundStyle(Palette.streak)
                        .accessibilityIdentifier("liveTutorNotice")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task { await session.run() }
        .onDisappear {
            let session = session
            Task { await session.end() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            guard
                let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                AVAudioSession.InterruptionType(rawValue: rawType) == .began
            else { return }
            session.interrupt(because: "a call or another app took over the audio")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                session.interrupt(because: "Dubby left the screen")
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch session.phase {
        case .connecting:
            HStack(spacing: 12) {
                ProgressView()
                    .tint(Palette.accentText)
                Text("Connecting to your tutor…")
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textPrimary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("liveTutorConnecting")
        case .live(let activity):
            Label(activity.title, systemImage: activity.systemImage)
                .dubFont(16, weight: .medium)
                .foregroundStyle(activity == .tutorSpeaking ? Palette.holo : Palette.textPrimary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.control))
                .accessibilityIdentifier("liveTutorActivity")
            Text("The tutor's voice is AI-generated.")
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.placeholder)
        case .ended(let reason):
            EmptyStateView(systemImage: "waveform.slash", title: "The practice call ended", message: reason ?? "Start it again from your dub's score.")
                .accessibilityIdentifier("liveTutorEnded")
            if session.needsMicrophoneAccess {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

private extension LiveTutorSession.Activity {
    var title: String {
        switch self {
        case .listening: "Listening… speak whenever you're ready."
        case .learnerSpeaking: "Hearing you…"
        case .tutorSpeaking: "Your tutor is speaking. Talk to cut in."
        }
    }

    var systemImage: String {
        switch self {
        case .listening: "ear"
        case .learnerSpeaking: "mic.fill"
        case .tutorSpeaking: "waveform"
        }
    }
}

private struct TranscriptLine: View {
    let line: LiveTutorTranscript.Line

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(line.speaker == .tutor ? "Tutor" : "You")
                .dubFont(12, weight: .semibold)
                .foregroundStyle(line.speaker == .tutor ? Palette.holo : Palette.textSecondary)
            Text(line.text.isEmpty ? "…" : line.text)
                .dubFont(16, weight: .regular)
                .foregroundStyle(Palette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
