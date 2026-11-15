import AVKit
import SwiftUI

struct LibrarySceneDetail: View {
    let clip: LibraryClip
    let onDub: () -> Void
    @State private var isPreviewPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VideoThumbnail(url: clip.url)
                    .aspectRatio(4 / 5, contentMode: .fit)
                    .overlay {
                        LinearGradient(colors: [.clear, Palette.background], startPoint: .center, endPoint: .bottom)
                    }
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 12) {
                            MetaPill(text: clip.durationSeconds.preciseClockString, systemImage: "film")
                            Text(clip.title)
                                .dubFont(32, weight: .bold)
                                .foregroundStyle(Palette.textPrimary)
                        }
                        .padding(20)
                    }
                VStack(alignment: .leading, spacing: 22) {
                    Text("A scene. A character. Your voice.")
                        .dubFont(22, weight: .bold)
                    Text("Choose up to 30 seconds of dialogue, pick who you'll play, and record their lines. Your finished dub is saved to Shelf.")
                        .dubFont(17, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                    Button {
                        isPreviewPresented = true
                    } label: {
                        Label("Preview scene", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("previewLibraryScene")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .foregroundStyle(Palette.textPrimary)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Dub this scene", action: onDub)
                .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
                .accessibilityIdentifier("dubScene-\(clip.sceneID)")
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Palette.background)
        }
        .sheet(isPresented: $isPreviewPresented) {
            LibraryScenePreview(clip: clip)
        }
    }
}

private struct LibraryScenePreview: View {
    let clip: LibraryClip
    @State private var player: AVPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(clip: LibraryClip) {
        self.clip = clip
        let player = AVPlayer(url: clip.url)
        player.isMuted = true
        _player = State(initialValue: player)
    }

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxHeight: .infinity)
                .screenBackground()
                .navigationTitle(clip.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .preferredColorScheme(.dark)
        .onAppear { if !reduceMotion { player.play() } }
        .onDisappear { player.pause() }
    }
}
