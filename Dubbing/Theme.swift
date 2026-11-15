import SwiftUI
import UIKit

/// Color tokens taken from the dub.it mockups.
enum Palette {
    static let background = Color(hex: 0x100D19)
    static let surface = Color(hex: 0x252131)
    static let track = Color(hex: 0x4B435B)
    static let segmentInactive = Color(hex: 0x383043)
    static let divider = Color(hex: 0x373043)
    static let accent = Color(hex: 0xA78BFA)
    static let accentText = Color(hex: 0xB5A0FF)
    static let onAccent = Color(hex: 0x100D19)
    static let textPrimary = Color(hex: 0xEDEDED)
    static let textSecondary = Color(hex: 0xCDCDCD)
    static let placeholder = Color(hex: 0xA6A1B5)
    static let streak = Color(hex: 0xFFB65C)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension View {
    /// System font at the mockup's point size for the default text size, scaled with Dynamic Type
    /// by the text style closest to that size.
    func dubFont(_ size: CGFloat, weight: Font.Weight) -> some View {
        modifier(ScaledFont(size: size, weight: weight))
    }
}

private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: Self.textStyle(nearest: size))
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }

    private static func textStyle(nearest size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<13: .caption
        case ..<15: .subheadline
        case ..<17: .callout
        case ..<19: .headline
        case ..<21: .title3
        case ..<25: .title2
        default: .title
        }
    }
}

/// Lays content out in a row, switching to a leading-aligned column at accessibility text sizes
/// so long words never wrap mid-word.
struct AdaptiveStack<Content: View>: View {
    let rowAlignment: VerticalAlignment
    let spacing: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: rowAlignment, spacing: spacing))
        layout { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Two flexible columns, or one at accessibility text sizes.
func adaptiveGridColumns(spacing: CGFloat, isAccessibilitySize: Bool) -> [GridItem] {
    let column = GridItem(.flexible(), spacing: spacing, alignment: .top)
    return isAccessibilitySize ? [column] : [column, column]
}

struct PrimaryButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dubFont(16, weight: .medium)
            .foregroundStyle(Palette.onAccent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Palette.accent, in: RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct OutlineCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
        }
        .dubFont(14, weight: .medium)
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, 16)
        .frame(minHeight: 36)
        .overlay(Capsule().strokeBorder(Palette.track, lineWidth: 1))
        .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct WaveformView: View {
    /// Bar heights from 0 to 1.
    let levels: [Float]
    let playedFraction: Double

    var body: some View {
        GeometryReader { proxy in
            let count = max(levels.count, 1)
            let spacing = 2.5
            let barWidth = max(1, (proxy.size.width - spacing * Double(count - 1)) / Double(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(levels.indices, id: \.self) { index in
                    let isPlayed = Double(index) / Double(count) < playedFraction
                    Capsule()
                        .fill(isPlayed ? Palette.accent : Palette.track)
                        // A minimum height keeps quiet bars visible as dots.
                        .frame(width: barWidth, height: max(3, proxy.size.height * Double(levels[index])))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

/// The first frame-ish thumbnail of a video, loaded off the main actor.
struct VideoThumbnail: View {
    let url: URL
    @State private var image: CGImage?
    @State private var failure: String?

    var body: some View {
        Palette.surface
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else if failure != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityLabel("Preview unavailable")
                }
            }
            .clipped()
            .task(id: url) {
                do {
                    image = try await MediaPipeline.thumbnails(for: url, count: 1, maximumSize: CGSize(width: 480, height: 270)).first
                } catch {
                    failure = error.localizedDescription
                }
            }
    }
}

/// A centered message for screens with nothing real to show yet.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .dubFont(32, weight: .regular)
                .foregroundStyle(Palette.accent)
            Text(title)
                .dubFont(18, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
            Text(message)
                .dubFont(14, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

struct BackHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "arrow.left")
                    .dubFont(16, weight: .medium)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back")
            Text(title)
                .dubFont(16, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            trailing
        }
    }
}
