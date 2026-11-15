import SwiftUI
import UIKit

/// Erica's character projector; a silhouette avoids implying actor recognition from a video frame.
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

/// The projector presents only measurements made on this take, keeping pronunciation claims separate.
struct TakeCoachPanel: View {
    let characterName: String
    let measurement: TakeMeasurement
    @State private var revealStart = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var message: String {
        switch measurement.level {
        case .silent: "The microphone heard no voice. Check it isn't covered, then record again."
        case .quiet: "Your take is quiet. Move a little closer to the microphone and try again."
        case .clear, nil:
            if let overrun = measurement.overrunSeconds {
                String(format: "Your take runs %.1f seconds past its window. Try a slightly quicker read so the ending stays in your dub.", overrun)
            } else {
                "Listen back to your take. Keep it when you're happy with the performance, or try another read."
            }
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let revealed = reduceMotion ? message.count : min(message.count, max(0, Int(context.date.timeIntervalSince(revealStart) * 40)))
            AdaptiveStack(rowAlignment: .top, spacing: 14) {
                HologramFigure(characterName: characterName, isSpeaking: revealed < message.count)
                    .frame(width: 104, height: 168)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(format: "%.1fs", measurement.takeSeconds))
                            .dubFont(40, weight: .bold)
                            .foregroundStyle(Palette.textPrimary)
                            .monospacedDigit()
                        Text("Take length")
                            .dubFont(13, weight: .semibold)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    caption(revealed: revealed)
                    Text("Pronunciation isn't measured here.")
                        .dubFont(12, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(16)
            .background {
                ZStack(alignment: .bottomLeading) {
                    Palette.surface
                    RadialGradient(colors: [Palette.holo.opacity(0.16), .clear], center: .bottomLeading, startRadius: 4, endRadius: 220)
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.poster))
            }
            .overlay(RoundedRectangle(cornerRadius: Radius.poster).strokeBorder(Palette.holo.opacity(0.18), lineWidth: 1))
        }
        .accessibilityIdentifier("takeFeedback")
        .overlay { StateCarriers(items: [StateCarrier(identifier: "feedbackBasis", value: measurement.feedbackBasis.rawValue)]) }
    }

    private func caption(revealed: Int) -> some View {
        let text = message
        let split = text.index(text.startIndex, offsetBy: revealed)
        return Text("\(Text(text[..<split]).foregroundStyle(Palette.holo))\(Text(text[split...]).foregroundStyle(.clear))")
            .dubFont(16, weight: .medium)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }
}
