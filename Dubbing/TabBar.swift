import SwiftUI

enum AppTab {
    case discover
    case messages
    case progress
    case myDubs
}

/// The app's floating Liquid Glass tab bar. It stays custom because the centre Create action has no system
/// tab equivalent and UI tests address the tabs by these identifiers.
struct DubTabBar: View {
    @Binding var selection: AppTab
    let onCreate: () -> Void
    @Namespace private var selectionIndicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: GlassMetrics.clusterSpacing) {
            HStack(spacing: 10) {
                tabGroup {
                    tabButton(.discover, title: "Discover", systemImage: "house", identifier: "tab-discover")
                    tabButton(.messages, title: "DMs", systemImage: "bubble.left.and.bubble.right", identifier: "tab-messages")
                }
                createButton
                tabGroup {
                    tabButton(.progress, title: "Progress", systemImage: "chart.bar", identifier: "tab-progress")
                    tabButton(.myDubs, title: "My Dubs", systemImage: "film", identifier: "tab-myDubs")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: selection)
    }

    private func tabGroup(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 0) {
            content()
        }
        .padding(4)
        .dubGlass(in: Capsule())
    }

    private var createButton: some View {
        Button(action: onCreate) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Palette.onAccent)
                .frame(width: 56, height: 56)
                .dubGlass(in: Circle(), tint: Palette.accent, interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Create")
        .accessibilityIdentifier("createDub")
        .accessibilityShowsLargeContentViewer {
            Label("Create", systemImage: "plus")
        }
    }

    private func tabButton(_ tab: AppTab, title: String, systemImage: String, identifier: String) -> some View {
        Button {
            selection = tab
        } label: {
            tabLabel(title: title, systemImage: systemImage, isActive: selection == tab)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
    }

    private func tabLabel(title: String, systemImage: String, isActive: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: isActive ? .semibold : .regular))
            Text(title)
                .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(isActive ? Palette.accentText : Palette.textPrimary)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background {
            if isActive {
                // A quiet fill marks the selection without stacking glass on glass.
                Capsule()
                    .fill(Palette.accent.opacity(0.18))
                    .matchedGeometryEffect(id: "selection", in: selectionIndicator)
            }
        }
        .contentShape(Capsule())
        // Tab bars keep a fixed size like the system one; long-press shows an enlarged label instead.
        .accessibilityShowsLargeContentViewer {
            Label(title, systemImage: systemImage)
        }
    }
}
