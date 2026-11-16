import SwiftUI

struct LibrarySceneDetail: View {
    let clip: LibraryClip
    let onDub: () -> Void
    let onClose: () -> Void
    @State private var isVisible = false
    @State private var bundledScript: PublishedSceneScript?

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
                        Text([clip.filmTitle, clip.languageName].compactMap { $0 }.joined(separator: " · "))
                            .dubFont(15, weight: .medium)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Text(clip.details?.synopsis ?? clip.blurb ?? "Pick who you'll play and record their lines. Your finished dub is saved to Shelf.")
                        .dubFont(17, weight: .regular)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    facts
                    if !castRows.isEmpty {
                        cast(castRows)
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
        .onAppear {
            isVisible = true
            bundledScript = PublishedSceneScript.bundled(for: clip.sceneID)
        }
        .onDisappear { isVisible = false }
    }

    /// A bundled script gives the real cast with faces; otherwise the backend's cast, then the known names.
    private var castRows: [CastRow] {
        if let script = bundledScript {
            return script.characters.indices.map { CastRow(name: script.characters[$0].name, lineCount: script.lineCount(of: $0), portrait: script.portraitURL(of: $0)) }
        }
        if let details = clip.details, !details.characters.isEmpty {
            return details.characters.map { CastRow(name: $0.name, lineCount: $0.lineCount, portrait: nil) }
        }
        return clip.castNames.map { CastRow(name: $0, lineCount: nil, portrait: nil) }
    }

    private var facts: some View {
        AdaptiveStack(rowAlignment: .center, spacing: 0) {
            if let language = clip.languageName {
                fact(value: language, label: "Language")
            }
            fact(value: "\(Int(clip.durationSeconds.rounded()))s", label: "Length")
            if let script = bundledScript {
                fact(value: "\(script.lines.count)", label: "Lines")
                fact(value: "\(script.characters.count)", label: "Roles")
            } else if let details = clip.details, !details.characters.isEmpty {
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

    private struct CastRow: Identifiable {
        let name: String
        let lineCount: Int?
        let portrait: URL?
        var id: String { name }
    }

    private func cast(_ characters: [CastRow]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast")
                .dubFont(17, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
            ForEach(characters) { character in
                HStack(spacing: 12) {
                    Group {
                        if let portrait = character.portrait, let image = UIImage(contentsOfFile: portrait.path(percentEncoded: false)) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "person.crop.circle")
                                .dubFont(32, weight: .light)
                                .foregroundStyle(Palette.textSecondary)
                                .frame(width: 44, height: 44)
                        }
                    }
                    .accessibilityHidden(true)
                    Text(character.name)
                        .dubFont(16, weight: .semibold)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                    if let lineCount = character.lineCount {
                        Text("\(lineCount) lines")
                            .dubFont(14, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
