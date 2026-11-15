import SwiftUI

/// The single exercise the coach recommends next, with the evidence it came from.
struct NextExerciseSection: View {
    let state: CoachRemoteState<NextExercise>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your next exercise")
                .dubFont(18, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            switch state {
            case .loading:
                ProgressView()
                    .tint(Palette.accentText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .accessibilityLabel("Choosing your next exercise")
            case .signedOut:
                SignInPrompt()
            case .failed(let message):
                EmptyStateView(systemImage: "exclamationmark.triangle", title: "Couldn't choose an exercise", message: message)
            case .loaded(let exercise):
                NextExerciseCard(exercise: exercise)
            }
        }
    }
}

struct NextExerciseCard: View {
    let exercise: NextExercise

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(exercise.kind.title)
                .dubFont(14, weight: .semibold)
                .foregroundStyle(Palette.accentText)
            if let practiceText = exercise.practiceText {
                Text(practiceText)
                    .dubFont(20, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(exercise.instruction)
                .dubFont(16, weight: .regular)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Focus: \(exercise.focus.title)")
                .dubFont(14, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
            Text(exercise.evidenceSummary)
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.placeholder)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nextExercise")
    }
}

/// Says whether the coach's feedback was measured from the voice or compared with the script.
struct FeedbackBasisLabel: View {
    let display: FeedbackBasisDisplay

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: display.systemImage)
                .dubFont(16, weight: .medium)
                .foregroundStyle(Palette.accentText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(display.title)
                    .dubFont(14, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
                Text(display.detail)
                    .dubFont(12, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feedbackBasis")
    }
}

struct SignInPrompt: View {
    var body: some View {
        EmptyStateView(
            systemImage: "person.crop.circle.badge.exclamationmark",
            title: "Sign in to use coaching",
            message: "Your coach reads your practice history, so it needs your account."
        )
        .accessibilityIdentifier("coachSignIn")
    }
}

/// Preferences and coaching memory, the two things the learner controls about their coach.
struct CoachPreferencesView: View {
    @State private var preferences: CoachPreferencesModel
    @State private var memory: CoachMemoryModel
    @State private var isConfirmingForget = false
    let practice: CoachPracticeContext?

    init(service: any CoachTutorService, practice: CoachPracticeContext?) {
        _preferences = State(initialValue: CoachPreferencesModel(service: service))
        _memory = State(initialValue: CoachMemoryModel(service: service))
        self.practice = practice
    }

    var body: some View {
        VStack(spacing: 0) {
            BackHeader(title: "Your coaching") { EmptyView() }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
            content
        }
        .background(Palette.background)
        .toolbar(.hidden, for: .navigationBar)
        .task { await preferences.load() }
        .task { await memory.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch preferences.phase {
        case .loading:
            ProgressView()
                .tint(Palette.accentText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
            SignInPrompt()
                .padding(16)
            Spacer()
        case .failed(let message):
            VStack(spacing: 12) {
                EmptyStateView(systemImage: "exclamationmark.triangle", title: "Couldn't load your preferences", message: message)
                Button("Try again") { Task { await preferences.load() } }
                    .buttonStyle(OutlineCapsuleButtonStyle())
            }
            .padding(16)
            Spacer()
        case .editing, .saving:
            form
        }
    }

    private var form: some View {
        @Bindable var preferences = preferences
        return Form {
            Section("What to work on") {
                Picker("Focus", selection: $preferences.draft.focus) {
                    ForEach(PracticeFocus.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Challenge", selection: $preferences.draft.challenge) {
                    ForEach(PracticeChallenge.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Session length", selection: $preferences.draft.sessionMinutes) {
                    Text("No preference").tag(SessionMinutes?.none)
                    ForEach(SessionMinutes.allCases, id: \.self) { Text($0.title).tag(SessionMinutes?.some($0)) }
                }
            }
            .listRowBackground(Palette.surface)
            Section {
                if let practice {
                    Toggle("Skip the line I'm practising", isOn: Binding(
                        get: { preferences.draft.avoidLineIds.contains(practice.lineID) },
                        set: { preferences.draft.setAvoiding(lineID: practice.lineID, isAvoiding: $0) }
                    ))
                }
                ForEach(preferences.draft.avoidLineIds, id: \.self) { lineID in
                    HStack {
                        Text("Line \(lineID)")
                        Spacer()
                        Button("Remove") { preferences.draft.setAvoiding(lineID: lineID, isAvoiding: false) }
                            .buttonStyle(.borderless)
                            .tint(Palette.accentText)
                            .accessibilityLabel("Stop skipping line \(lineID)")
                    }
                }
            } header: {
                Text("Lines to skip")
            } footer: {
                Text(preferences.draft.avoidLineIds.isEmpty ? "Your coach can suggest any line." : "Your coach won't suggest these lines.")
            }
            .listRowBackground(Palette.surface)
            Section {
                TextField("What do you want to get better at?", text: Binding(
                    get: { preferences.draft.goalNote ?? "" },
                    set: { preferences.draft.goalNote = $0 }
                ), axis: .vertical)
                .lineLimit(2...6)
            } header: {
                Text("Your goal")
            } footer: {
                if preferences.draft.isGoalNoteTooLong {
                    Text("Keep your goal under \(CoachPreferences.goalNoteLimit) characters.")
                        .foregroundStyle(Palette.streak)
                } else {
                    Text("Your own words. Your coach reads this to stay on track.")
                }
            }
            .listRowBackground(Palette.surface)
            Section {
                Button(preferences.phase == .saving ? "Saving…" : "Save preferences") {
                    Task { await preferences.save() }
                }
                .disabled(!preferences.canSave)
                .accessibilityIdentifier("savePreferences")
                if let notice = preferences.notice {
                    Text(notice).foregroundStyle(Palette.textSecondary)
                }
                if let saveError = preferences.saveError {
                    Text(saveError).foregroundStyle(Palette.streak)
                }
            }
            .listRowBackground(Palette.surface)
            memorySection
        }
        .scrollContentBackground(.hidden)
        .tint(Palette.accentText)
        .confirmationDialog("Forget your coaching memory?", isPresented: $isConfirmingForget, titleVisibility: .visible) {
            Button("Forget everything", role: .destructive) { Task { await memory.forget() } }
        } message: {
            Text("Your coach will forget the practice notes and goal it saved. Your attempts, scores, and saved preferences stay.")
        }
    }

    private var memorySection: some View {
        Section {
            switch memory.status {
            case .loading:
                ProgressView().tint(Palette.accentText)
            case .signedOut:
                Text("Sign in to see what your coach remembers.")
            case .failed(let message):
                Text(message).foregroundStyle(Palette.streak)
            case .loaded(let status):
                Text(status.summary)
            }
            if let notice = memory.notice {
                Text(notice).foregroundStyle(Palette.textSecondary)
            }
            if let forgetError = memory.forgetError {
                Text(forgetError).foregroundStyle(Palette.streak)
            }
            Button("Forget my coaching memory", role: .destructive) { isConfirmingForget = true }
                .disabled(memory.isForgetting || memory.status.isEmptyLoaded)
                .accessibilityIdentifier("forgetMemory")
        } header: {
            Text("Coaching memory")
        } footer: {
            Text("Your coach saves short practice notes and your goal so it can pick up where you left off. Scores and recordings aren't stored there.")
        }
        .listRowBackground(Palette.surface)
    }
}

private extension CoachRemoteState where Value == CoachMemoryStatus {
    /// True once the status loaded and holds nothing, so there is nothing to forget.
    var isEmptyLoaded: Bool {
        guard case .loaded(let status) = self else { return false }
        return status.storedCount == 0
    }
}
