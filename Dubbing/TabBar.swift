import SwiftUI

enum AppTab {
    case discover
    case messages
    case progress
    case myDubs
}

struct DubTabBar: View {
    @Binding var selection: AppTab
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Palette.divider)
                .frame(height: 1)
            HStack(alignment: .bottom) {
                tabButton(.discover, title: "Discover", systemImage: "house")
                tabButton(.messages, title: "DMs", systemImage: "bubble.left.and.bubble.right")
                Button(action: onCreate) {
                    VStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Palette.onAccent)
                            .frame(width: 36, height: 36)
                            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 16))
                        Text("Create")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.textPrimary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("createDub")
                .accessibilityShowsLargeContentViewer {
                    Label("Create", systemImage: "plus")
                }
                tabButton(.progress, title: "Progress", systemImage: "chart.bar")
                tabButton(.myDubs, title: "My Dubs", systemImage: "film")
            }
            .padding(.top, 8)
        }
        .background(Palette.background)
    }

    private func tabButton(_ tab: AppTab, title: String, systemImage: String) -> some View {
        Button {
            selection = tab
        } label: {
            tabLabel(title: title, systemImage: systemImage, isActive: selection == tab)
        }
        .buttonStyle(.plain)
    }

    private func tabLabel(title: String, systemImage: String, isActive: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
            Text(title)
                .font(.system(size: 12))
        }
        .foregroundStyle(isActive ? Palette.accentText : Palette.textPrimary)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        // Tab bars keep a fixed size like the system one; long-press shows an enlarged label instead.
        .accessibilityShowsLargeContentViewer {
            Label(title, systemImage: systemImage)
        }
    }
}
