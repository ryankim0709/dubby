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
    static let textPrimary = Color(hex: 0xF2F2F2)
    static let textSecondary = Color(hex: 0x9A9A9A)
    static let placeholder = Color(hex: 0x7C7C7C)
    static let accent = Color(hex: 0xF2F2F2)
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
            assertionFailure("LeagueGothic.ttf is missing from the app bundle")
            return
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            assertionFailure("Couldn't register League Gothic: \(String(describing: error?.takeRetainedValue()))")
        }
    }
}

private func textStyle(nearest size: CGFloat) -> Font.TextStyle {
    switch size {
    case ..<13: .caption
    case ..<15: .subheadline
    case ..<17: .callout
    case ..<19: .headline
    case ..<21: .title3
    case ..<25: .title2
    case ..<30: .title
    default: .largeTitle
    }
}

extension View {
    /// System font at a design point size, scaled with Dynamic Type by the nearest text style.
    func dubFont(_ size: CGFloat, weight: Font.Weight) -> some View {
        modifier(ScaledFont(size: size, weight: weight))
    }

    /// Poster display face at a design point size, scaled with Dynamic Type.
    func displayFont(_ size: CGFloat) -> some View {
        font(.custom(DisplayFont.postScriptName, size: size, relativeTo: textStyle(nearest: size)))
    }
}

private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle(nearest: size))
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dubFont(17, weight: .semibold)
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Palette.accent.opacity(isEnabled ? 1 : 0.35), in: RoundedRectangle(cornerRadius: Radius.control))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dubFont(17, weight: .semibold)
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.control))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Shows the bundled image when it exists; until real (licensed) art is added to
/// Assets.xcassets under `imageName`, the placeholder gradient stands in.
struct ArtworkView: View {
    let artwork: Artwork

    var body: some View {
        LinearGradient(colors: artwork.placeholder, startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                if let image = UIImage(named: artwork.imageName) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
    }
}

struct AvatarView: View {
    let friend: Friend
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: friend.avatar, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Text(String(friend.name.prefix(1)))
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
            }
            .accessibilityHidden(true)
    }
}

/// Overlapping avatars for co-created dubs, like a collab credit.
struct AvatarStack: View {
    let friends: [Friend]
    let size: CGFloat

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(friends) { friend in
                AvatarView(friend: friend, size: size)
                    .overlay(Circle().stroke(Palette.background, lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A small capsule of metadata on top of imagery or surfaces.
struct MetaPill: View {
    let text: String
    let systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .dubFont(13, weight: .semibold)
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, 10)
        .frame(minHeight: 26)
        .background(.black.opacity(0.45), in: Capsule())
    }
}

extension Double {
    /// Formats seconds as `m:ss`.
    var clockString: String {
        let total = Int(rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension Int {
    /// Compact counts like 12.4k for social numbers.
    var compactCount: String {
        self >= 1000 ? String(format: "%.1fk", Double(self) / 1000) : "\(self)"
    }
}
