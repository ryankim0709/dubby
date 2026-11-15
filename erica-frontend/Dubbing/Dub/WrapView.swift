import AVKit
import SwiftUI

/// The finished dub: render it, watch it, then save, share, post, or pass the other role to a friend.
struct WrapView: View {
    let summary: DubSummary
    @Environment(AppModel.self) private var model
    @State private var render: RenderState = .rendering
    @State private var save: SaveState = .idle
    @State private var isPublic = true
    @State private var player = AVPlayer()

    private enum RenderState: Equatable {
        case rendering
        case ready(URL)
        case failed(String)
    }

    private enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    private var character: SceneCharacter? { summary.scene.character(id: summary.characterID) }
    private var otherRole: SceneCharacter? { summary.scene.characters.first { $0.id != summary.characterID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("That's a wrap")
                        .dubFont(34, weight: .bold)
                        .foregroundStyle(Palette.textPrimary)
                    Text("\(summary.scene.title) · you as \(character?.name ?? "")\(summary.partner.map { " with \($0.name)" } ?? "")")
                        .dubFont(15, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                }
                preview
                lineScores
                actions
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(render == .rendering)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { finish() }
                    .disabled(render == .rendering)
            }
        }
        .task { await renderDub() }
        .onDisappear { player.pause() }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            switch render {
            case .rendering:
                Color.black
                VStack(spacing: 10) {
                    ProgressView().tint(Palette.textPrimary)
                    Text("Mixing your voice into the scene")
                        .dubFont(14, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                }
            case .ready:
                VideoPlayer(player: player)
            case .failed(let message):
                Color.black
                VStack(spacing: 12) {
                    Text(message)
                        .dubFont(14, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") {
                        Task { await renderDub() }
                    }
                    .foregroundStyle(Palette.accent)
                }
                .padding()
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
    }

    private var lineScores: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(summary.scene.lines(for: summary.characterID)) { line in
                HStack(spacing: 12) {
                    Text(line.text)
                        .dubFont(15, weight: .regular)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(summary.timingScores[line.id].map(String.init) ?? "–")
                        .dubFont(22, weight: .bold)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textPrimary)
                        .accessibilityLabel(summary.timingScores[line.id].map { "Timing \($0)" } ?? "No timing measured")
                }
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if case .ready(let url) = render {
            VStack(spacing: 12) {
                Toggle(isOn: $isPublic) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Post to the feed")
                            .dubFont(16, weight: .semibold)
                            .foregroundStyle(Palette.textPrimary)
                        Text(isPublic ? "Anyone can watch and react" : "Only on your shelf")
                            .dubFont(13, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .tint(Palette.toggleOn)
                .padding(14)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card))

                HStack(spacing: 10) {
                    Button {
                        Task { await saveToPhotos(url) }
                    } label: {
                        Label(saveTitle, systemImage: save == .saved ? "checkmark" : "square.and.arrow.down")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(save == .saving || save == .saved)
                    ShareLink(item: url, preview: SharePreview(summary.scene.title)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                if case .failed(let message) = save {
                    Text(message)
                        .dubFont(13, weight: .regular)
                        .foregroundStyle(Palette.record)
                }
                if summary.partner == nil, let otherRole {
                    ShareLink(
                        item: inviteURL(for: otherRole),
                        subject: Text("Dub with me"),
                        message: Text("I dubbed \(character?.name ?? "my part") in “\(summary.scene.title)”. Take \(otherRole.name) and we'll post it together.")
                    ) {
                        Label("Invite a friend to dub \(otherRole.name)", systemImage: "person.2.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var saveTitle: String {
        switch save {
        case .idle, .failed: "Save video"
        case .saving: "Saving…"
        case .saved: "Saved"
        }
    }

    /// App link for a co-dub invite. Swap for a universal link once the backend hosts invites.
    private func inviteURL(for role: SceneCharacter) -> URL {
        var components = URLComponents()
        components.scheme = "dubby"
        components.host = "codub"
        components.path = "/\(summary.scene.id)"
        components.queryItems = [URLQueryItem(name: "role", value: role.id)]
        return components.url ?? URL(filePath: "/")
    }

    private func renderDub() async {
        render = .rendering
        do {
            let url = try await DubExporter.render(summary)
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            // The app stays silent; the exported file keeps its audio for Photos and sharing.
            player.isMuted = true
            render = .ready(url)
        } catch {
            render = .failed("The video couldn't be rendered. \(error.localizedDescription)")
        }
    }

    private func saveToPhotos(_ url: URL) async {
        save = .saving
        do {
            try await PhotoLibrary.saveVideo(at: url)
            save = .saved
        } catch MediaError.photoAccessDenied {
            save = .failed("Allow Dubby to add photos in Settings to save your dub.")
        } catch {
            save = .failed("Couldn't save the video. \(error.localizedDescription)")
        }
    }

    private func finish() {
        if case .ready(let url) = render {
            model.file(summary, videoURL: url, visibility: isPublic ? .publicFeed : .privateShelf)
        }
        model.activeDub = nil
    }
}
