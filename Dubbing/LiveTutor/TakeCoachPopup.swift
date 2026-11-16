import SwiftUI

/// The coach that pops up after recording: measured timing and one short tip about the current line.
/// The suggested action is ringed, and the buttons never move, so the learner accepts or declines it with one tap.
struct TakeCoachPopup: View {
    static let charactersPerSecond = 40.0

    let characterName: String
    let lineText: String
    let timing: TakeTiming
    let measurement: TakeMeasurement
    /// Nil when this build or account has no live coach.
    let coach: TakeCoach.State?
    let isPlayingTake: Bool
    let canPlayTake: Bool
    let canRetry: Bool
    let canKeep: Bool
    let onPlayTake: () -> Void
    let onRetry: () -> Void
    let onKeep: () -> Void
    let onDismiss: () -> Void
    @State private var isDismissed = false
    @State private var revealStart = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A voice the microphone barely picked up is worth fixing before timing.
    private var isQuiet: Bool { timing != .noVoice && measurement.level == .quiet }

    private var message: String {
        if case .suggested(let suggestion) = coach { return suggestion.tip }
        if case .listening = coach { return "" }
        if case .unavailable = coach { return "" }
        return isQuiet ? TakeMeasurement.quietAdvice : timing.tip(cue: TakeTiming.cueWord(in: lineText))
    }

    private var suggested: TakeCoach.Suggestion.Action {
        if case .suggested(let suggestion) = coach { return suggestion.suggestion }
        return timing.suggestsRetry || isQuiet ? .retry : .keep
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || isDismissed)) { context in
            let revealed = revealedCount(at: context.date)
            panel(revealed: revealed, isTalking: revealed < message.count)
        }
        .onChange(of: message) { revealStart = .now }
        .accessibilityIdentifier("takeCoach")
    }

    private func revealedCount(at date: Date) -> Int {
        // The AI tip arrives complete; displaying it immediately avoids a second wait for typewriter animation.
        if case .suggested = coach { return message.count }
        guard !reduceMotion else { return message.count }
        // A timeline frame can be dated just before a reset `revealStart`, which would make the count negative.
        return min(message.count, max(0, Int(date.timeIntervalSince(revealStart) * Self.charactersPerSecond)))
    }

    private func panel(revealed: Int, isTalking: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(isDismissed ? "Your take" : "Take coach").dubFont(17, weight: .semibold)
                Spacer()
                if !isDismissed {
                    Button {
                        onDismiss()
                        isDismissed = true
                    } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss tutor")
                    .accessibilityIdentifier("dismissTakeCoach")
                }
            }
            if !isDismissed {
                HStack(alignment: .top, spacing: 14) {
                    HologramFigure(characterName: characterName, isSpeaking: isTalking)
                    .frame(width: 96, height: 156)
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Timing")
                                .dubFont(13, weight: .semibold)
                                .foregroundStyle(Palette.textSecondary)
                            Text(timing.label)
                                .dubFont(17, weight: .semibold)
                                .foregroundStyle(Palette.textPrimary)
                        }
                        .accessibilityElement(children: .combine)
                        if !message.isEmpty {
                            caption(revealed: revealed)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        status
                    }
                }
            }
            actions
        }
        .padding(16)
        .background {
            ZStack(alignment: .bottomLeading) {
                Palette.surface
                // Light spilling from the projector onto the panel.
                RadialGradient(colors: [Palette.holo.opacity(0.16), .clear], center: .bottomLeading, startRadius: 4, endRadius: 220)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.poster))
        }
        .overlay(RoundedRectangle(cornerRadius: Radius.poster).strokeBorder(Palette.holo.opacity(0.18), lineWidth: 1))
    }

    /// The tip types out as the hologram talks. The unrevealed rest is laid out but invisible, so the panel keeps
    /// its final size instead of growing line by line.
    private func caption(revealed: Int) -> some View {
        let text = message
        let split = text.index(text.startIndex, offsetBy: min(revealed, text.count))
        return Text("\(Text(text[..<split]).foregroundStyle(Palette.holo))\(Text(text[split...]).foregroundStyle(.clear))")
            .dubFont(16, weight: .medium)
            .accessibilityLabel("\(characterName) says: \(text)")
            .accessibilityIdentifier("takeCoachTip")
    }

    @ViewBuilder
    private var status: some View {
        switch coach {
        case .listening:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Palette.holo)
                Text("Checking this line…")
                    .dubFont(12, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)
        case .unavailable(let reason):
            Text("Your coach couldn't listen to this take. \(reason)")
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityIdentifier("takeCoachUnavailable")
        case .suggested, nil:
            EmptyView()
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: onPlayTake) {
                Image(systemName: isPlayingTake ? "stop.fill" : "play.fill")
                    .frame(width: 52, height: 52)
                    .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.control))
                    .foregroundStyle(Palette.textPrimary)
            }
            .disabled(!canPlayTake)
            .accessibilityLabel(isPlayingTake ? "Stop your take" : "Play your take")
            .accessibilityIdentifier("playTake")
            Button(action: onRetry) {
                // Same size as Keep, so neither choice reads as the lesser one.
                Text("Retry")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(SecondaryButtonStyle())
                .suggestionRing(suggested == .retry)
                .disabled(!canRetry)
                .accessibilityIdentifier("retryTake")
            Button(action: onKeep) {
                Label("Keep", systemImage: "checkmark")
            }
            .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
            .suggestionRing(suggested == .keep)
            .disabled(!canKeep)
            .accessibilityIdentifier("keepTake")
        }
    }
}

private extension View {
    /// Marks the action the coach suggests, for sight and for VoiceOver.
    func suggestionRing(_ isSuggested: Bool) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: Radius.control + 3)
                .strokeBorder(Palette.holo.opacity(isSuggested ? 0.9 : 0), lineWidth: 2)
                .padding(-3)
                .allowsHitTesting(false)
        }
        .accessibilityHint(isSuggested ? "Your coach suggests this" : "")
    }
}
