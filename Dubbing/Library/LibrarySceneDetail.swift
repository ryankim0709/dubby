import SwiftUI

struct LibrarySceneDetail: View {
    let clip: LibraryClip
    let onDub: () -> Void
    let onClose: () -> Void
    @State private var isVisible = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LibraryVideoPreview(clip: clip, isActive: isVisible)
                    .aspectRatio(4 / 5, contentMode: .fit)
                    .overlay {
                        LinearGradient(colors: [.clear, Palette.background], startPoint: .center, endPoint: .bottom)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(clip.sceneTitle)
                            .dubFont(32, weight: .bold)
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text([clip.sourceTitle, clip.languageName].compactMap { $0 }.joined(separator: " · "))
                            .dubFont(15, weight: .medium)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Text(clip.details?.synopsis ?? "Choose up to 30 seconds of dialogue, pick who you'll play, and record their lines. Your finished dub is saved to Shelf.")
                        .dubFont(17, weight: .regular)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    facts
                    if let details = clip.details, !details.characters.isEmpty {
                        cast(details.characters)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .ignoresSafeArea(edges: .top)
        .scrollIndicators(.hidden)
        .screenBackground()
        .safeAreaInset(edge: .bottom) {
            AdaptiveStack(rowAlignment: .center, spacing: 10) {
                Button("Not now", action: onClose)
                    .buttonStyle(SecondaryButtonStyle())
                Button("Dub this scene", action: onDub)
                    .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
                    .accessibilityIdentifier("dubScene-\(clip.sceneID)")
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Palette.background)
        }
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close scene", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("closeLibraryScene")
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    private var facts: some View {
        AdaptiveStack(rowAlignment: .center, spacing: 0) {
            if let language = clip.languageName {
                fact(value: language, label: "Language")
            }
            fact(value: "\(Int(clip.durationSeconds.rounded()))s", label: "Length")
            if let details = clip.details, !details.characters.isEmpty {
                fact(value: "\(details.characters.reduce(0) { $0 + $1.lineCount })", label: "Lines")
                fact(value: "\(details.characters.count)", label: "Roles")
            }
        }
        .padding(.vertical, 14)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card))
    }

    private func fact(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .dubFont(16, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
            Text(label)
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }

    private func cast(_ characters: [LibrarySceneDetails.Character]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast")
                .dubFont(17, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
            ForEach(characters) { character in
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle")
                        .dubFont(32, weight: .light)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    Text(character.name)
                        .dubFont(16, weight: .semibold)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                    Text("\(character.lineCount) lines")
                        .dubFont(14, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
