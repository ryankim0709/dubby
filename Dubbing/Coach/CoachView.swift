import AVFoundation
import LiveKit
import SwiftUI

/// Where the coach's navigation stack can go from the roster.
private enum CoachRoute: Hashable {
    case character(CoachCharacter)
    case preferences
}

/// Pick a scene character to coach you, and the language to practise. `practice` is the line the
/// dub flow is on, when the coach is opened from there; it lets the coach talk about that line.
struct CoachView: View {
    let practice: CoachPracticeContext?
    let tokens: any CoachAuthTokenProvider
    let onClose: () -> Void
    @State private var roster: LoadState<[CoachCharacter]> = .loading
    @State private var exercise: CoachRemoteState<NextExercise> = .loading
    @State private var language: SpokenLanguage

    /// Opens the coach with no practice line and nobody signed in. The dub flow and the app's sign-in
    /// should call `init(practice:tokens:onClose:)` instead.
    init(onClose: @escaping () -> Void) {
        self.init(practice: nil, tokens: SignedOutCoachTokens(), onClose: onClose)
    }

    init(practice: CoachPracticeContext?, tokens: any CoachAuthTokenProvider, onClose: @escaping () -> Void) {
        self.practice = practice
        self.tokens = tokens
        self.onClose = onClose
        _language = State(initialValue: SpokenLanguage.all.first { $0.identifier == practice?.locale } ?? SpokenLanguage.all[0])
    }

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
                        NavigationLink(value: CoachRoute.preferences) {
                            Image(systemName: "slider.horizontal.3")
                                .dubFont(16, weight: .medium)
                                .foregroundStyle(Palette.textPrimary)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("Your coaching preferences and memory")
                        .accessibilityIdentifier("coachPreferences")
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
                    NextExerciseSection(state: exercise)
                    LoadStateContent(state: roster) { roster in
                        VStack(spacing: 12) {
                            ForEach(roster) { character in
                                NavigationLink(value: CoachRoute.character(character)) {
                                    CharacterRow(character: character)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("coach-\(character.id)")
                            }
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
            .navigationDestination(for: CoachRoute.self) { route in
                destination(for: route)
            }
        }
        .preferredColorScheme(.dark)
        .task { await loadRoster() }
        .task(id: language) { await loadExercise() }
    }

    private func loadRoster() async {
        do {
            let backend = try CoachBackendClient.configured(in: .main, tokens: tokens)
            roster = .loaded(try await backend.characters())
        } catch is CancellationError {
            return
        } catch {
            roster = .failed(error.localizedDescription)
        }
    }

    @ViewBuilder
    private func destination(for route: CoachRoute) -> some View {
        switch Result(catching: { try CoachBackendClient.configured(in: .main, tokens: tokens) }) {
        case .failure(let error):
            EmptyStateView(systemImage: "exclamationmark.triangle", title: "Couldn't open this", message: error.localizedDescription)
                .padding(16)
        case .success(let backend):
            switch route {
            case .character(let character):
                CoachSessionView(session: CoachSession(character: character, language: language, backend: backend, practice: practice, exercise: exercise))
            case .preferences:
                CoachPreferencesView(service: backend, practice: practice)
            }
        }
    }

    /// Reloaded when the practice language changes, since an exercise belongs to one locale.
    private func loadExercise() async {
        exercise = .loading
        exercise = await CoachRemoteState.result {
            try await CoachBackendClient.configured(in: .main, tokens: tokens).nextExercise(locale: language.identifier)
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
    @Environment(\.openURL) private var openURL

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
                if let reply = session.lastReply,
                   let basis = reply.feedbackBasis.display(citedEvidenceCount: reply.citedEvidenceIds.count) {
                    FeedbackBasisLabel(display: basis)
                }
                NextExerciseSection(state: session.exercise)
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
                    if session.needsMicrophoneAccess {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .buttonStyle(OutlineCapsuleButtonStyle())
                    }
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
