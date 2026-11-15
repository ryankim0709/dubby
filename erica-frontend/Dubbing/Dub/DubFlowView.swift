import SwiftUI

enum DubFlowRoute: Hashable {
    case studio(characterID: String)
    case wrap(DubSummary)
}

/// The immersive dubbing flow, presented full screen from any tab: cast, dub line by line, wrap.
struct DubFlowView: View {
    let request: DubRequest
    @State private var path: [DubFlowRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            CastingView(request: request) { characterID in
                path.append(.studio(characterID: characterID))
            }
            .navigationDestination(for: DubFlowRoute.self) { route in
                switch route {
                case .studio(let characterID):
                    if let character = request.scene.character(id: characterID) {
                        StudioView(scene: request.scene, character: character, partner: request.partner) { summary in
                            path.append(.wrap(summary))
                        }
                    }
                case .wrap(let summary):
                    WrapView(summary: summary)
                }
            }
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
    }
}

/// Pick who to become. A co-dub invite arrives with the role already chosen.
struct CastingView: View {
    let request: DubRequest
    let onStart: (String) -> Void
    @State private var selectedID: String?
    @Environment(\.dismiss) private var dismiss

    init(request: DubRequest, onStart: @escaping (String) -> Void) {
        self.request = request
        self.onStart = onStart
        _selectedID = State(initialValue: request.lockedCharacterID ?? request.scene.characters.first?.id)
    }

    private var scene: SceneClip { request.scene }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Choose your role")
                        .dubFont(32, weight: .bold)
                        .foregroundStyle(Palette.textPrimary)
                    Text("\(scene.source.title) · \(scene.language)")
                        .dubFont(15, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                }
                if let partner = request.partner, let theirs = scene.characters.first(where: { $0.id != request.lockedCharacterID }) {
                    HStack(spacing: 10) {
                        AvatarView(friend: partner, size: 32)
                        Text("\(partner.name) already dubbed \(theirs.name). Their lines play while you record yours.")
                            .dubFont(14, weight: .regular)
                            .foregroundStyle(Palette.textPrimary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card))
                }
                HStack(alignment: .top, spacing: 12) {
                    ForEach(scene.characters) { character in
                        RoleCard(
                            character: character,
                            lines: scene.lines(for: character.id),
                            isSelected: character.id == selectedID,
                            isLocked: request.lockedCharacterID != nil && request.lockedCharacterID != character.id,
                            takenBy: request.lockedCharacterID != nil && request.lockedCharacterID != character.id ? request.partner : nil
                        ) {
                            selectedID = character.id
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            Button(startTitle) {
                if let selectedID { onStart(selectedID) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(selectedID == nil)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .background(Palette.background)
        }
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close", systemImage: "xmark") { dismiss() }
            }
        }
    }

    private var startTitle: String {
        guard let selectedID, let character = scene.character(id: selectedID) else { return "Pick a role" }
        return "Dub as \(character.name)"
    }
}

private struct RoleCard: View {
    let character: SceneCharacter
    let lines: [ScriptLine]
    let isSelected: Bool
    let isLocked: Bool
    let takenBy: Friend?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                ArtworkView(artwork: character.artwork)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        Text(character.name.uppercased())
                            .displayFont(34)
                            .foregroundStyle(Palette.textPrimary)
                            .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                            .padding(10)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(Palette.onAccent, Palette.accent)
                                .padding(8)
                        } else if let takenBy {
                            AvatarView(friend: takenBy, size: 28)
                                .padding(8)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.card)
                            .strokeBorder(isSelected ? Palette.accent : .clear, lineWidth: 2.5)
                    }
                Text(character.tagline)
                    .dubFont(14, weight: .medium)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(lines.count) lines · \(Int(speakingSeconds.rounded()))s of dialogue")
                    .dubFont(13, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
                if let first = lines.first {
                    Text("“\(first.text)”")
                        .dubFont(14, weight: .regular)
                        .italic()
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isLocked ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var speakingSeconds: Double {
        lines.reduce(0) { $0 + ($1.end - $1.start) }
    }
}
