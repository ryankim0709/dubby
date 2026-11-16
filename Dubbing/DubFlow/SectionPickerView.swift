import Speech
import SwiftUI

private enum ThumbnailState {
    case loading
    case loaded([CGImage])
    case failed(String)
}

private struct DialogueTask: Equatable {
    let language: SpokenLanguage
    let attempt: Int
}

private struct PreparationTask: Equatable {
    let request: TranscriptionRequest
    let dialogue: SceneDialoguePhase
    let attempt: Int
}

struct SectionPickerView: View {
    let clip: ImportedClip
    let onTranscribe: (PreparedScript) -> Void
    @State private var player: SegmentPlayer
    @State private var selection: TimeSpan
    @State private var language: SpokenLanguage
    @State private var thumbnails: ThumbnailState = .loading
    @State private var previewTask: Task<Void, Never>?
    @State private var dialogue: SceneDialoguePhase = .loading
    @State private var preparation: ScriptPreparationPhase = .preparing
    @State private var attempt = 0

    init(clip: ImportedClip, onTranscribe: @escaping (PreparedScript) -> Void) {
        self.clip = clip
        self.onTranscribe = onTranscribe
        let code = clip.locale.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
        _language = State(initialValue: SpokenLanguage.all.first { Locale(identifier: $0.identifier).language.languageCode?.identifier == code } ?? SpokenLanguage.all[0])
        _player = State(initialValue: SegmentPlayer(url: clip.url))
        _selection = State(initialValue: TimeSpan(start: 0, end: min(clip.durationSeconds, SectionEditing.defaultLength)))
    }

    private var request: TranscriptionRequest {
        TranscriptionRequest(clip: clip, section: ClipSection(start: selection.start, end: selection.end), language: language)
    }

    private var prepared: PreparedScript? {
        guard case .ready(let script) = preparation, script.request == request else { return nil }
        return script
    }

    private var issue: FlowIssue? {
        if case .failed(let issue) = dialogue { return issue }
        if case .failed(let issue) = preparation { return issue }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Find your moment")
                    .dubFont(32, weight: .bold)
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                SectionVideoPreview(url: clip.url, start: selection.start, player: player)
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
                if let issue {
                    IssueCard(
                        title: issue.opensSettings ? "Speech recognition is off" : "The script couldn't be built",
                        issue: issue,
                        identifier: issue.opensSettings ? "speechPermissionNotice" : "transcribeError",
                        value: issue.opensSettings ? (SFSpeechRecognizer.authorizationStatus() == .restricted ? "restricted" : "denied") : issue.code,
                        retryTitle: "Try again",
                        retryIdentifier: "transcribeRetry",
                        retry: { attempt += 1 }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .containerIdentifier("sectionScreen")
        }
        .scrollIndicators(.hidden)
        // Pinned so the primary action stays on screen however tall the framing controls get.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                if prepared == nil, issue == nil {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(Palette.textSecondary)
                        Text("Preparing your script…")
                            .dubFont(14, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Button("Transcribe scene") {
                    guard let prepared else { return }
                    stopPreview()
                    onTranscribe(prepared)
                }
                .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
                .disabled(prepared == nil)
                .accessibilityIdentifier("transcribeScene")
            }
            .padding(16)
            .background(Palette.background)
        }
        .screenBackground()
        .navigationTitle("Frame the scene")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            StateCarriers(items: [StateCarrier(identifier: "transcribeProgress", value: prepared != nil ? "ready" : issue != nil ? "failed" : "preparing")])
        }
        .task(id: DialogueTask(language: language, attempt: attempt)) { await loadDialogue() }
        .task(id: PreparationTask(request: request, dialogue: dialogue, attempt: attempt)) { await prepareScript() }
        .task {
            do {
                thumbnails = .loaded(try await MediaPipeline.thumbnails(for: clip.url, count: 10, maximumSize: CGSize(width: 240, height: 136)))
            } catch {
                thumbnails = .failed(error.localizedDescription)
            }
        }
        .onDisappear { stopPreview() }
    }

    private func loadDialogue() async {
        if case .ready(let loadedLanguage, _) = dialogue, loadedLanguage == language { return }
        dialogue = .loading
        let selectedLanguage = language
        do {
            let loaded = try await ScriptPreparation.dialogue(for: clip, language: selectedLanguage)
            try Task.checkCancellation()
            dialogue = .ready(selectedLanguage, loaded)
        } catch {
            guard !Task.isCancelled else { return }
            dialogue = .failed(FlowIssue(error: error))
        }
    }

    private func prepareScript() async {
        if prepared != nil { return }
        preparation = .preparing
        guard case .ready(let loadedLanguage, let loaded) = dialogue, loadedLanguage == language else { return }
        let selectedRequest = request
        do {
            // Wait for the framing gesture to settle before exporting another audio section.
            try await Task.sleep(for: .milliseconds(300))
            let script = try await ScriptPreparation.prepare(selectedRequest, dialogue: loaded)
            try Task.checkCancellation()
            preparation = .ready(script)
        } catch {
            guard !Task.isCancelled else { return }
            preparation = .failed(FlowIssue(error: error))
        }
    }

    @ViewBuilder
    private var timeline: some View {
        switch thumbnails {
        case .loading:
            SectionTimeline(duration: clip.durationSeconds, selection: selection, thumbnails: [], onSelectionChange: select, onEditingEnd: preview)
        case .loaded(let images):
            SectionTimeline(duration: clip.durationSeconds, selection: selection, thumbnails: images, onSelectionChange: select, onEditingEnd: preview)
        case .failed(let message):
            SectionTimeline(duration: clip.durationSeconds, selection: selection, thumbnails: [], onSelectionChange: select, onEditingEnd: preview)
            Text("Couldn't load preview frames: \(message)")
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.streak)
        }
    }

    private func select(_ span: TimeSpan) {
        stopPreview()
        selection = span
    }

    private func preview() {
        let span = selection
        previewTask = Task {
            await player.seek(to: span.start)
            guard !Task.isCancelled else { return }
            _ = await player.play(until: span.end, volume: 1)
            guard !Task.isCancelled else { return }
            player.stop()
            previewTask = nil
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        player.stop()
    }
}

private struct SectionVideoPreview: View {
    let url: URL
    let start: Double
    let player: SegmentPlayer
    @State private var picture: VideoPicture?
    @State private var failure: String?

    var body: some View {
        Color.black
            .overlay {
                if let picture {
                    Image(decorative: picture.image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .overlay {
                            if player.isPlaying {
                                ScenePreviewSurface(player: player.player, picture: picture)
                            }
                        }
                } else if failure == nil {
                    ProgressView().tint(Palette.textPrimary)
                }
            }
            .overlay {
                if let failure {
                    Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                        .dubFont(13, weight: .medium)
                        .foregroundStyle(Palette.textPrimary)
                        .padding(10)
                        .background(.black.opacity(0.55))
                        .accessibilityHint(failure)
                }
            }
            .clipped()
            .task(id: start) {
                do {
                    let nextPicture = try await MediaPipeline.previewPicture(for: url, at: start)
                    try Task.checkCancellation()
                    picture = nextPicture
                    failure = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    failure = error.localizedDescription
                }
            }
    }
}

/// A filmstrip of the clip with a draggable selection window.
private struct SectionTimeline: View {
    let duration: Double
    let selection: TimeSpan
    let thumbnails: [CGImage]
    let onSelectionChange: (TimeSpan) -> Void
    let onEditingEnd: () -> Void
    @GestureState private var dragOrigin: TimeSpan?

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
            .updating($dragOrigin) { _, origin, _ in
                if origin == nil { origin = selection }
            }
            .onChanged { value in
                let origin = dragOrigin ?? selection
                onSelectionChange(SectionEditing.adjusted(
                    origin: origin,
                    handle: handle,
                    delta: value.translation.width / width * duration,
                    clipDuration: duration
                ))
            }
            .onEnded { _ in onEditingEnd() }
    }
}
