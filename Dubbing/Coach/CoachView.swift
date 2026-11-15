import AVFoundation
import LiveKit
import SwiftUI

/// The coaches the backend offers, and the client that reaches them.
private struct CoachRoster {
    let backend: CoachBackendClient
    let characters: [CoachCharacter]
}

/// Pick a scene character to coach you, and the language to practise.
struct CoachView: View {
    let onClose: () -> Void
    @State private var roster: LoadState<CoachRoster> = .loading
    @State private var language = SpokenLanguage.all[0]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .dubFont(16, weight: .medium)
                                .foregroundStyle(Palette.textPrimary)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("Close")
                        Text("Talk to a coach")
                            .dubFont(16, weight: .semibold)
                            .foregroundStyle(Palette.textPrimary)
                        Spacer()
                    }
                    Text("Pick who teaches you. They'll listen to what you say and coach you out loud.")
                        .dubFont(14, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                    AdaptiveStack(rowAlignment: .center, spacing: 8) {
                        Text("Practise in")
                            .dubFont(14, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                        Picker("Language", selection: $language) {
                            ForEach(SpokenLanguage.all) { Text($0.name).tag($0) }
                        }
                        .tint(Palette.accentText)
                        .accessibilityIdentifier("coachLanguage")
                    }
                    LoadStateContent(state: roster) { roster in
                        VStack(spacing: 12) {
                            ForEach(roster.characters) { character in
                                NavigationLink(value: character) {
                                    CharacterRow(character: character)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("coach-\(character.id)")
                            }
                        }
                        .navigationDestination(for: CoachCharacter.self) { character in
                            CoachSessionView(session: CoachSession(character: character, language: language, backend: roster.backend))
                        }
                    }
                    Text("What you say is transcribed on this iPhone. The text goes to Anthropic's Claude to write your coach's reply, and LiveAvatar by HeyGen turns that reply into the coach's voice and video.")
                        .dubFont(12, weight: .regular)
                        .foregroundStyle(Palette.placeholder)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .background(Palette.background)
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task { await loadRoster() }
    }

    private func loadRoster() async {
        do {
            let backend = try CoachBackendClient.configured(in: .main)
            roster = .loaded(CoachRoster(backend: backend, characters: try await backend.characters()))
        } catch {
            roster = .failed(error.localizedDescription)
        }
    }
}

private struct CharacterRow: View {
    let character: CoachCharacter

    var body: some View {
        HStack(spacing: 12) {
            Text(String(character.name.prefix(1)))
                .dubFont(20, weight: .semibold)
                .foregroundStyle(Palette.onAccent)
                .frame(width: 48, height: 48)
                .background(Palette.accent, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(character.name)
                    .dubFont(18, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
                Text(character.summary)
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// The call with one coach: their video, what each of you said, and one button to talk.
struct CoachSessionView: View {
    @State private var session: CoachSession
    @Environment(\.scenePhase) private var scenePhase

    init(session: CoachSession) {
        _session = State(initialValue: session)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BackHeader(title: session.character.name) { EmptyView() }
                    .padding(.top, 8)
                avatarCard
                transcript
                if case .ended(let reason) = session.connection {
                    EmptyStateView(systemImage: "video.slash", title: "The call ended", message: reason)
                } else {
                    talkControls
                        .frame(maxWidth: .infinity)
                }
                if let errorMessage = session.errorMessage {
                    Text(errorMessage)
                        .dubFont(14, weight: .regular)
                        .foregroundStyle(Palette.streak)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .background(Palette.background)
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
                session.interrupt(because: "DubIt left the screen")
            }
        }
    }

    private var avatarCard: some View {
        Color.black
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                if let track = session.videoTrack {
                    SwiftUIVideoView(track, layoutMode: .fit)
                        .accessibilityLabel("\(session.character.name)'s video")
                } else if session.connection == .connecting || session.connection == .live {
                    VStack(spacing: 8) {
                        ProgressView().tint(Palette.accentText)
                        Text(session.connection == .connecting ? "Calling \(session.character.name)…" : "Waiting for video…")
                            .dubFont(14, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(session.turns.enumerated()), id: \.offset) { _, turn in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(turn.role == .coach ? session.character.name : "You")
                        .dubFont(12, weight: .semibold)
                        .foregroundStyle(turn.role == .coach ? Palette.accentText : Palette.textSecondary)
                    Text(turn.text)
                        .dubFont(16, weight: .regular)
                        .foregroundStyle(Palette.textPrimary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var talkControls: some View {
        VStack(spacing: 10) {
            Button(action: session.talkButtonTapped) {
                Image(systemName: talkIcon)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(session.activity == .listening ? .white : Palette.onAccent)
                    .frame(width: 78, height: 78)
                    .background(session.activity == .listening ? Color.red : Palette.accent, in: Circle())
            }
            .disabled(session.connection != .live || session.activity == .transcribing || session.activity == .thinking)
            .opacity(session.connection != .live ? 0.5 : 1)
            .accessibilityLabel(talkLabel)
            .accessibilityIdentifier("coachTalk")
            Text(talkHint)
                .dubFont(14, weight: .regular)
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var talkIcon: String {
        switch session.activity {
        case .idle, .transcribing, .thinking: "mic"
        case .listening: "stop.fill"
        case .speaking: "hand.raised"
        }
    }

    private var talkLabel: String {
        switch session.activity {
        case .idle, .transcribing, .thinking: "Talk to \(session.character.name)"
        case .listening: "Send what you said"
        case .speaking: "Interrupt \(session.character.name)"
        }
    }

    private var talkHint: String {
        switch session.activity {
        case .idle: session.turns.isEmpty ? "Tap and say something in \(session.language.name)." : "Tap to answer"
        case .listening: "Listening… tap when you're done"
        case .transcribing: "Writing down what you said"
        case .thinking: "\(session.character.name) is thinking"
        case .speaking: "Tap to cut in"
        }
    }
}
