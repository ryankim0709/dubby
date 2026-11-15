import CoreText
import SwiftUI
import UIKit

/// Screening-room tokens: neutral charcoal lit by a soft glow behind the content, white for
/// what's selected or actionable and grey for everything else. The only hues are functional:
/// recording red while the mic is live, and hologram cyan reserved for the coach.
enum Palette {
    static let background = Color(hex: 0x0F0F0F)
    /// The light pooling behind the top of each screen, fading out to `background`.
    static let backgroundGlow = Color(hex: 0x2C2C2C)
    static let surface = Color(hex: 0x1C1C1C)
    static let surfaceRaised = Color(hex: 0x2A2A2A)
    static let hairline = Color(hex: 0x2C2C2C)
    static let track = Color(hex: 0x3A3A3A)
    static let segmentInactive = Color(hex: 0x3A3A3A)
    static let divider = Color(hex: 0x2C2C2C)
    static let textPrimary = Color(hex: 0xF2F2F2)
    static let textSecondary = Color(hex: 0x9A9A9A)
    static let placeholder = Color(hex: 0x7C7C7C)
    static let accent = Color(hex: 0xF2F2F2)
    static let accentText = Color(hex: 0xF2F2F2)
    static let streak = Color(hex: 0x9A9A9A)
    static let onAccent = Color(hex: 0x0F0F0F)
    /// Switches keep the system's green: a white track would hide the white knob.
    static let toggleOn = Color(hex: 0x34C759)
    static let record = Color(hex: 0xFF4D3D)
    static let holo = Color(hex: 0x6FF2FF)
    static let shelfWood = Color(hex: 0x2E2E2E)
    static let shelfWoodShadow = Color(hex: 0x141414)
}

/// Corner radii from the reference: big soft posters, slightly tighter cards and controls.
enum Radius {
    static let poster: CGFloat = 22
    static let card: CGFloat = 18
    static let control: CGFloat = 16
}

/// The screen ground: charcoal with a soft glow behind the top-centre content.
struct ScreenBackground: View {
    var body: some View {
        ZStack {
            Palette.background
            RadialGradient(
                colors: [Palette.backgroundGlow, Palette.background],
                center: UnitPoint(x: 0.5, y: 0.28),
                startRadius: 0,
                endRadius: 460
            )
        }
        .ignoresSafeArea()
    }
}

extension View {
    func screenBackground() -> some View {
        background { ScreenBackground() }
    }
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

/// League Gothic is used only where it imitates printed poster art (titles on placeholder
/// posters, DVD cases, the wordmark); SF carries all interface text, headings included.
enum DisplayFont {
    static let postScriptName = "LeagueGothic-Regular"

    /// The generated Info.plist can't list UIAppFonts, so the bundled face is registered for this process at launch.
    static func register() {
        guard let url = Bundle.main.url(forResource: "LeagueGothic", withExtension: "ttf") else {
            preconditionFailure("LeagueGothic.ttf is missing from the app bundle")
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            preconditionFailure("Couldn't register League Gothic: \(String(describing: error?.takeRetainedValue()))")
        }
    }
}

extension View {
    func displayFont(_ size: CGFloat) -> some View {
        font(.custom(DisplayFont.postScriptName, size: size, relativeTo: .largeTitle))
    }

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
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dubFont(17, weight: .semibold)
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Palette.accent.opacity(isEnabled ? 1 : 0.35), in: RoundedRectangle(cornerRadius: cornerRadius))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) { configuration.label }
            .dubFont(17, weight: .semibold)
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.control))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct MetaPill: View {
    let text: String
    let systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .dubFont(13, weight: .semibold)
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, 10)
        .frame(minHeight: 26)
        .background(.black.opacity(0.45), in: Capsule())
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
    let time: Double?
    @State private var image: CGImage?
    @State private var failure: String?

    init(url: URL) {
        self.url = url
        time = nil
    }

    init(url: URL, time: Double) {
        self.url = url
        self.time = time
    }

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
            .task(id: ThumbnailRequest(url: url, time: time)) {
                do {
                    failure = nil
                    if let time {
                        image = try await MediaPipeline.thumbnail(for: url, at: time, maximumSize: CGSize(width: 640, height: 640))
                    } else {
                        image = try await MediaPipeline.previewPicture(for: url).image
                    }
                } catch {
                    failure = error.localizedDescription
                }
            }
    }
}

private struct ThumbnailRequest: Equatable {
    let url: URL
    let time: Double?
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
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
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
