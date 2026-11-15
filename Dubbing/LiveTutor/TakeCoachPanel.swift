import SwiftUI

/// The coach that pops up after a take: the character as a hologram, the measured timing, and what to try next.
/// The phone's timing tip shows at once; when the live coach has listened, its own tip and suggestion replace it.
/// The suggested action is ringed, and the buttons never move, so the learner accepts or declines it with one tap.
struct TakeCoachPanel: View {
    static let charactersPerSecond = 40.0

    let characterName: String
    let lineText: String
    let timing: TakeTiming
    /// Nil when this build or account has no live coach.
    let coach: TakeCoach.State?
    let isCoachSpeaking: Bool
    let isPlayingTake: Bool
    let canPlayTake: Bool
    let canRetry: Bool
    let canKeep: Bool
    let onPlayTake: () -> Void
    let onRetry: () -> Void
    let onKeep: () -> Void
    @State private var revealStart = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var message: String {
        if case .suggested(let suggestion) = coach { return suggestion.tip }
        return timing.tip(cue: TakeTiming.cueWord(in: lineText))
    }

    private var suggested: TakeCoach.Suggestion.Action {
        if case .suggested(let suggestion) = coach { return suggestion.suggestion }
        return timing.suggestsRetry ? .retry : .keep
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let revealed = revealedCount(at: context.date)
            panel(revealed: revealed, isTalking: isCoachSpeaking || revealed < message.count)
        }
        .onChange(of: message) { revealStart = .now }
        .accessibilityIdentifier("takeCoach")
    }

    private func revealedCount(at date: Date) -> Int {
        guard !reduceMotion else { return message.count }
        return min(message.count, Int(date.timeIntervalSince(revealStart) * Self.charactersPerSecond))
    }

    private func panel(revealed: Int, isTalking: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
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
                    caption(revealed: revealed)
                        .fixedSize(horizontal: false, vertical: true)
                    status
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
                Text("Listening to your take…")
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

/// The character, projected: a cyan figure standing in a beam over an emitter disc.
struct HologramFigure: View {
    let characterName: String
    let isSpeaking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                let size = proxy.size
                ZStack(alignment: .bottom) {
                    BeamShape()
                        .fill(LinearGradient(
                            colors: [Palette.holo.opacity(0.32), Palette.holo.opacity(0.05), .clear],
                            startPoint: .bottom,
                            endPoint: .top
                        ))
                        .frame(height: size.height * 0.92)
                        .opacity(beamOpacity(at: time))
                    figure(time: time, height: size.height * 0.78)
                        .padding(.bottom, size.height * 0.07)
                    emitter(width: size.width * 0.62, time: time)
                }
                .frame(width: size.width, height: size.height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Hologram of \(characterName)")
    }

    private func figure(time: Double, height: CGFloat) -> some View {
        ZStack {
            silhouette
                .foregroundStyle(Palette.holo)
                .mask(ScanlineMask())
            // A bright band rolling down through the figure, as if it's being redrawn.
            silhouette
                .foregroundStyle(.white)
                .mask {
                    GeometryReader { proxy in
                        let travel = reduceMotion ? 0.5 : (time * 0.45).truncatingRemainder(dividingBy: 1)
                        LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 18)
                            .offset(y: proxy.size.height * travel - 9)
                    }
                }
                .blendMode(.plusLighter)
        }
        .frame(height: height)
        .mask(LinearGradient(colors: [.white, .white, .white.opacity(0.35)], startPoint: .top, endPoint: .bottom))
        .shadow(color: Palette.holo.opacity(0.55), radius: 10)
        .opacity(flicker(at: time))
        .offset(x: glitchOffset(at: time))
        .scaleEffect(isSpeaking && !reduceMotion ? 1 + 0.012 * sin(time * 14) : 1, anchor: .bottom)
    }

    private var silhouette: some View {
        Image(systemName: "figure.stand")
            .resizable()
            .scaledToFit()
            .fontWeight(.ultraLight)
    }

    private func emitter(width: CGFloat, time: Double) -> some View {
        ZStack {
            Ellipse()
                .fill(Palette.surfaceRaised)
                .frame(width: width, height: width * 0.2)
                .offset(y: width * 0.04)
            Ellipse()
                .fill(Palette.holo.opacity(0.7))
                .frame(width: width * 0.62, height: width * 0.1)
                .blur(radius: 4)
                .opacity(isSpeaking && !reduceMotion ? 0.7 + 0.3 * abs(sin(time * 9)) : 0.75)
            Ellipse()
                .stroke(Palette.holo.opacity(0.6), lineWidth: 1)
                .frame(width: width * 0.8, height: width * 0.14)
        }
    }

    private func flicker(at time: Double) -> Double {
        guard !reduceMotion else { return 0.9 }
        let shimmer = 0.86 + 0.06 * sin(time * 31) + 0.04 * sin(time * 7.3)
        let dropout = sin(time * 1.7) * sin(time * 5.3) > 0.93
        return dropout ? 0.5 : shimmer
    }

    private func glitchOffset(at time: Double) -> CGFloat {
        guard !reduceMotion else { return 0 }
        return sin(time * 0.9) > 0.992 ? 3 : 0
    }

    private func beamOpacity(at time: Double) -> Double {
        reduceMotion ? 0.9 : 0.85 + 0.15 * sin(time * 3.1)
    }
}

/// Narrow at the emitter, widening upward.
private struct BeamShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bottomInset = rect.width * 0.34
        path.move(to: CGPoint(x: rect.minX + bottomInset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - bottomInset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Horizontal scanlines: alternating solid and translucent rows.
private struct ScanlineMask: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 2)), with: .color(.white))
                context.fill(Path(CGRect(x: 0, y: y + 2, width: size.width, height: 1.5)), with: .color(.white.opacity(0.35)))
                y += 3.5
            }
        }
    }
}
