import AVKit
import SwiftUI

struct MyDubsView: View {
    let dubs: LoadState<[SavedDub]>
    let folder: URL
    @State private var playing: SavedDub?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("My Dubs")
                    .dubFont(24, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.top, 8)
                LoadStateContent(state: dubs) { dubs in
                    if dubs.isEmpty {
                        EmptyStateView(
                            systemImage: "film",
                            title: "No dubs yet",
                            message: "Dub a scene from Discover and it shows up here, ready to watch and share."
                        )
                    } else {
                        Text("\(dubs.count) \(dubs.count == 1 ? "dub" : "dubs") saved on this iPhone")
                            .dubFont(14, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                        LazyVGrid(
                            columns: adaptiveGridColumns(spacing: 8, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize),
                            spacing: 16
                        ) {
                            ForEach(dubs) { dub in
                                Button {
                                    playing = dub
                                } label: {
                                    SavedDubCard(dub: dub, video: DubLibrary.videoURL(for: dub, in: folder))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .background(Palette.background)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $playing) { dub in
            SavedDubPlayer(dub: dub, video: DubLibrary.videoURL(for: dub, in: folder))
        }
    }
}

private struct SavedDubCard: View {
    let dub: SavedDub
    let video: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VideoThumbnail(url: video)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.bottom, 8)
            Text(dub.sceneTitle)
                .dubFont(14, weight: .medium)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Text("as \(dub.characterName) · \(dub.createdAt.formatted(.relative(presentation: .named)))")
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
            Text("\(dub.linesDubbed)/\(dub.totalLines) lines in your voice")
                .dubFont(12, weight: .semibold)
                .foregroundStyle(Palette.accentText)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct SavedDubPlayer: View {
    let dub: SavedDub
    let video: URL
    @State private var player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    init(dub: SavedDub, video: URL) {
        self.dub = dub
        self.video = video
        _player = State(initialValue: AVPlayer(url: video))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dub.sceneTitle)
                        .dubFont(18, weight: .semibold)
                        .foregroundStyle(Palette.textPrimary)
                    Text("as \(dub.characterName)")
                        .dubFont(14, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .dubFont(16, weight: .semibold)
                    .foregroundStyle(Palette.accentText)
            }
            VideoPlayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .onAppear { player.play() }
                .onDisappear { player.pause() }
            ShareLink(item: video) {
                Label("Share dub", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryButtonStyle(cornerRadius: 16))
            Spacer()
        }
        .padding(16)
        .background(Palette.background)
        .preferredColorScheme(.dark)
    }
}
