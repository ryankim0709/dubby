import SwiftUI

/// What the pronunciation tutor has to say about a finished dub. The backend's assessment fills
/// this; until it's connected the app shows a sample built from the script, labelled as such.
struct TutorReport: Hashable {
    /// True for the placeholder: nothing here was measured from the user's recordings.
    let isSample: Bool
    let greeting: String
    let lines: [TutorLineFeedback]

    func feedback(for lineID: String) -> TutorLineFeedback? {
        lines.first { $0.lineID == lineID }
    }

    /// Placeholder until the tutor service exists: highlights each line's longest word, the one
    /// learners most often rush, with a generic practice tip. Never presented as a measurement.
    static func sample(character: SceneCharacter, lines: [ScriptLine]) -> TutorReport {
        TutorReport(
            isSample: true,
            greeting: "You made it through the scene. I'm \(character.name), and I'll be your tutor. Let's make every word land.",
            lines: lines.map { line in
                let word = line.text
                    .split(separator: " ")
                    .map { Glossary.key(for: String($0)) }
                    .max { $0.count < $1.count } ?? ""
                return TutorLineFeedback(
                    lineID: line.id,
                    wordsToPractice: [word],
                    tip: "Say “\(word)” slowly, one syllable at a time, then bring it back up to speed."
                )
            }
        )
    }
}

struct TutorLineFeedback: Hashable {
    let lineID: String
    /// Glossary keys of the words to work on, matched against the line's words.
    let wordsToPractice: [String]
    let tip: String
}

/// Full-screen takeover after the last line: the character steps out of the scene as a hologram
/// tutor and walks through the user's lines one by one.
struct TutorTakeoverView: View {
    static let charactersPerSecond = 40.0

    let character: SceneCharacter
    let lines: [ScriptLine]
    let report: TutorReport
    let onPractice: (ScriptLine) -> Void
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = Date.now

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                        let revealed = revealedCount(at: context.date)
                        VStack(spacing: 20) {
                            HologramFigure(character: character, isSpeaking: revealed < report.greeting.count)
                                .frame(width: 170, height: 260)
                            greeting(revealed: revealed)
                        }
                    }
                    if report.isSample {
                        Label("Sample feedback · tutor service not connected", systemImage: "info.circle")
                            .dubFont(13, weight: .medium)
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 30)
                            .background(Palette.surfaceRaised, in: Capsule())
                    }
                    VStack(spacing: 14) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            TutorLineCard(
                                number: index + 1,
                                line: line,
                                feedback: report.feedback(for: line.id),
                                onPractice: { onPractice(line) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background {
                ZStack {
                    ScreenBackground()
                    // The beam's light washing the top of the room.
                    RadialGradient(colors: [Palette.holo.opacity(0.14), .clear], center: UnitPoint(x: 0.5, y: 0.18), startRadius: 0, endRadius: 320)
                        .ignoresSafeArea()
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Continue to wrap", action: onContinue)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .background(Palette.background)
            }
            .navigationTitle("Pronunciation tutor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .tint(Palette.accent)
    }

    private func revealedCount(at date: Date) -> Int {
        guard !reduceMotion else { return report.greeting.count }
        return min(report.greeting.count, Int(date.timeIntervalSince(appeared) * Self.charactersPerSecond))
    }

    /// Typed out as the hologram talks; the unrevealed rest keeps its space so nothing jumps.
    private func greeting(revealed: Int) -> some View {
        let text = report.greeting
        let split = text.index(text.startIndex, offsetBy: revealed)
        return Text("\(Text(text[..<split]).foregroundStyle(Palette.textPrimary))\(Text(text[split...]).foregroundStyle(.clear))")
            .dubFont(22, weight: .bold)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("\(character.name) says: \(text)")
    }
}

private struct TutorLineCard: View {
    let number: Int
    let line: ScriptLine
    let feedback: TutorLineFeedback?
    let onPractice: () -> Void

    private var practiceWords: Set<String> { Set(feedback?.wordsToPractice ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Line \(number)")
                .dubFont(13, weight: .semibold)
                .foregroundStyle(Palette.textSecondary)
            FlowLayout(spacing: 6, lineSpacing: 2) {
                ForEach(Array(line.text.split(separator: " ").enumerated()), id: \.offset) { _, word in
                    let needsWork = practiceWords.contains(Glossary.key(for: String(word)))
                    Text(String(word))
                        .foregroundStyle(needsWork ? Palette.holo : Palette.textPrimary)
                        .underline(needsWork, color: Palette.holo)
                }
            }
            .dubFont(22, weight: .bold)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line.text)
            if let feedback {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "waveform")
                        .foregroundStyle(Palette.holo)
                        .accessibilityHidden(true)
                    Text(feedback.tip)
                        .dubFont(15, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: onPractice) {
                Label("Practice this line", systemImage: "mic.fill")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card))
    }
}
