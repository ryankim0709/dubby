import SwiftUI

/// Learner preferences, stored per device. Defaults: learning aids on in Chinese, coach on.
enum SettingsKey {
    static let homeLanguage = "homeLanguage"
    static let learningMode = "learningMode"
    static let coachAfterTake = "coachAfterTake"
}

/// The learning preferences as form rows, shared by the Shelf settings sheet and the studio menu.
struct LearningSettingsSection: View {
    @AppStorage(SettingsKey.homeLanguage) private var homeLanguage: HomeLanguage = .chinese
    @AppStorage(SettingsKey.learningMode) private var learningMode = true
    @AppStorage(SettingsKey.coachAfterTake) private var coachAfterTake = true

    var body: some View {
        Section {
            Toggle("Language learning", isOn: $learningMode)
                .tint(Palette.toggleOn)
            Picker("Home language", selection: $homeLanguage) {
                ForEach(HomeLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .disabled(!learningMode)
        } footer: {
            Text(learningMode
                ? "Shows each line's meaning in your home language. Tap any word in a line to see what it means."
                : "Just the script, for dubbing in a language you already speak.")
        }
        Section {
            Toggle("Character coach", isOn: $coachAfterTake)
                .tint(Palette.toggleOn)
        } footer: {
            Text("After each take, the character you're dubbing tells you how your timing landed and what to try next.")
        }
    }
}

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                LearningSettingsSection()
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Palette.accent)
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.background)
    }
}
