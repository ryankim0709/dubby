import SwiftUI

private enum ThumbnailState {
    case loading
    case loaded([CGImage])
    case failed(String)
}

struct SectionPickerView: View {
    let clip: ImportedClip
    let onTranscribe: (TranscriptionRequest) -> Void
    @State private var player: SegmentPlayer
    @State private var selection: TimeSpan
    @State private var language = SpokenLanguage.all[0]
    @State private var thumbnails: ThumbnailState = .loading
    @State private var previewTask: Task<Void, Never>?

    init(clip: ImportedClip, onTranscribe: @escaping (TranscriptionRequest) -> Void) {
        self.clip = clip
        self.onTranscribe = onTranscribe
        _player = State(initialValue: SegmentPlayer(url: clip.url))
        _selection = State(initialValue: TimeSpan(start: 0, end: min(clip.durationSeconds, SectionEditing.defaultLength)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BackHeader(title: "Frame the scene") { EmptyView() }
                    .padding(.top, 8)
                PlayerSurface(player: player.player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Clip preview")
                Text("Drag the handles to frame up to \(Int(SectionEditing.maximumLength)) seconds of dialogue.")
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
                timeline
                AdaptiveStack(rowAlignment: .center, spacing: 8) {
                    Text("\(selection.start.preciseClockString) – \(selection.end.preciseClockString)")
                        .dubFont(14, weight: .regular)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Text(String(format: "%.1f s selected", selection.end - selection.start))
                        .dubFont(14, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(Palette.accentText)
                }
                AdaptiveStack(rowAlignment: .center, spacing: 8) {
                    Text("Spoken language")
                        .dubFont(16, weight: .medium)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                    Picker("Spoken language", selection: $language) {
                        ForEach(SpokenLanguage.all) { language in
                            Text(language.name).tag(language)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Palette.accentText)
                }
                .padding(12)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                #if targetEnvironment(simulator)
                Text("This library scene is processed by OpenAI to build your script.")
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
                #endif
                AdaptiveStack(rowAlignment: .center, spacing: 12) {
                    Button {
                        if player.isPlaying {
                            player.stop()
                        } else {
                            preview()
                        }
                    } label: {
                        Image(systemName: player.isPlaying ? "stop.fill" : "play.fill")
                        Text(player.isPlaying ? "Stop" : "Preview scene")
                    }
                    .buttonStyle(OutlineCapsuleButtonStyle())
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .containerIdentifier("sectionScreen")
        }
        .scrollIndicators(.hidden)
        // Pinned so the primary action stays on screen however tall the framing controls get.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Transcribe scene") {
                player.stop()
                onTranscribe(TranscriptionRequest(
                    clip: clip,
                    section: ClipSection(start: selection.start, end: selection.end),
                    language: language
                ))
            }
            .buttonStyle(PrimaryButtonStyle(cornerRadius: 16))
            .accessibilityIdentifier("transcribeScene")
            .padding(16)
            .background(Palette.background)
        }
        .background(Palette.background)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await player.seek(to: selection.start)
            do {
                thumbnails = .loaded(try await MediaPipeline.thumbnails(for: clip.url, count: 10, maximumSize: CGSize(width: 240, height: 136)))
            } catch {
                thumbnails = .failed(error.localizedDescription)
            }
        }
        .onChange(of: selection.start) { _, start in
            previewTask?.cancel()
            player.stop()
            Task { await player.seek(to: start) }
        }
        .onDisappear { player.stop() }
    }

    @ViewBuilder
    private var timeline: some View {
        switch thumbnails {
        case .loading:
            SectionTimeline(duration: clip.durationSeconds, selection: $selection, thumbnails: [])
        case .loaded(let images):
            SectionTimeline(duration: clip.durationSeconds, selection: $selection, thumbnails: images)
        case .failed(let message):
            SectionTimeline(duration: clip.durationSeconds, selection: $selection, thumbnails: [])
            Text("Couldn't load preview frames: \(message)")
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.streak)
        }
    }

    private func preview() {
        previewTask?.cancel()
        let span = selection
        previewTask = Task {
            await player.seek(to: span.start)
            _ = await player.play(until: span.end, volume: 1)
            player.stop()
            await player.seek(to: span.start)
        }
    }
}

/// A filmstrip of the clip with a draggable selection window.
private struct SectionTimeline: View {
    let duration: Double
    @Binding var selection: TimeSpan
    let thumbnails: [CGImage]
    @State private var dragOrigin: TimeSpan?

    private let height: CGFloat = 56

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let startX = width * selection.start / duration
            let endX = width * selection.end / duration
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(thumbnails.indices, id: \.self) { index in
                        Image(decorative: thumbnails[index], scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: width / CGFloat(thumbnails.count), height: height)
                            .clipped()
                    }
                }
                .frame(width: width, height: height, alignment: .leading)
                .background(Palette.surface)
                Rectangle()
                    .fill(.black.opacity(0.6))
                    .frame(width: startX, height: height)
                Rectangle()
                    .fill(.black.opacity(0.6))
                    .frame(width: max(0, width - endX), height: height)
                    .offset(x: endX)
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.accent, lineWidth: 3)
                    .contentShape(Rectangle())
                    .frame(width: max(0, endX - startX), height: height)
                    .offset(x: startX)
                    .gesture(drag(.move, width: width))
                handle
                    .offset(x: startX - 16)
                    .gesture(drag(.start, width: width))
                    .accessibilityLabel("Scene start")
                handle
                    .offset(x: endX - 16)
                    .gesture(drag(.end, width: width))
                    .accessibilityLabel("Scene end")
            }
        }
        .frame(height: height)
    }

    private var handle: some View {
        Capsule()
            .fill(Palette.accent)
            .frame(width: 10, height: height)
            .overlay(Capsule().fill(Palette.onAccent).frame(width: 2, height: 18))
            // A wider invisible hit area makes the thin handle easy to grab.
            .frame(width: 32, height: height)
            .contentShape(Rectangle())
    }

    private func drag(_ handle: SectionHandle, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let origin = dragOrigin ?? selection
                dragOrigin = origin
                selection = SectionEditing.adjusted(
                    origin: origin,
                    handle: handle,
                    delta: value.translation.width / width * duration,
                    clipDuration: duration
                )
            }
            .onEnded { _ in dragOrigin = nil }
    }
}
