import AVKit
import os
import Photos
import SwiftUI

private enum ExportPhase: Equatable {
    case filteringDialogue
    case mixing
    case measuring
    case saving
    case finished(video: URL, trimmed: [TakePlacement], measurements: [TakeMeasurement])
    case cancelled
    case failed(FlowIssue)

    /// What a UI test reads from `exportStatus`.
    var stateValue: String {
        switch self {
        case .filteringDialogue: "filteringDialogue"
        case .mixing: "mixing"
        case .measuring: "measuring"
        case .saving: "saving"
        case .finished: "finished"
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }

    /// What a UI test reads from `savedStatus`; nil until saving starts.
    var savedValue: String? {
        switch self {
        case .saving: "saving"
        case .finished: "saved"
        default: nil
        }
    }
}

/// Mixes the takes into the scene, saves the dub to the library, and shows it. Export can be cancelled
/// until saving starts, and a cancelled or failed export leaves nothing in My Dubs.
struct DubResultView: View {
    let setup: DubSetup
    let takes: [Int: RecordedTake]
    let account: AccountModel
    /// Nil when the build has no backend.
    let scoring: DubScoringModel?
    let completionRoom: CoDubRoom?
    let onDone: () -> Void
    @State private var phase: ExportPhase = .filteringDialogue
    @State private var savedDubID: UUID?
    @State private var attempt = 0
    @State private var exportTask: Task<Void, Never>?
    @State private var saveFailed = false
    @State private var isCoDubUploading = false
    @State private var isInviting = false
    @State private var photoSave: PhotoSave = .idle

    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "export")
    private let history = LocalDubHistory(folder: DubLibrary.defaultFolder)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .filteringDialogue, .mixing, .measuring:
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(Palette.accentText)
                        Text(progressTitle)
                            .dubFont(16, weight: .medium)
                            .foregroundStyle(Palette.textPrimary)
                        Button("Cancel export", action: cancelExport)
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityIdentifier("cancelExport")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                case .saving:
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(Palette.accentText)
                        Text(progressTitle)
                            .dubFont(16, weight: .medium)
                            .foregroundStyle(Palette.textPrimary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                    .accessibilityElement(children: .combine)
                case .finished(let video, _, _):
                    finished(video: video)
                case .cancelled:
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Export cancelled", systemImage: "xmark.circle")
                            .dubFont(16, weight: .semibold)
                            .foregroundStyle(Palette.textPrimary)
                        Text("Nothing was saved. Your takes are still here if you export again.")
                            .dubFont(14, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                        Button("Export again", action: startExport)
                            .buttonStyle(PrimaryButtonStyle(cornerRadius: 16))
                            .accessibilityIdentifier("retryExport")
                    }
                    .padding(12)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                case .failed(let issue):
                    IssueCard(
                        title: "The dub couldn't be exported",
                        issue: issue,
                        identifier: "exportError",
                        value: issue.code,
                        retryTitle: "Try again",
                        retryIdentifier: "retryExport",
                        retry: startExport
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 16)
            .containerIdentifier("exportScreen")
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        // Pinned so the actions and Done stay reachable however long the screen gets.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .finished(let video, _, _) = phase {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Button(action: { saveToPhotos(video) }) {
                            Label(photoSave.title, systemImage: photoSave.systemImage)
                        }
                        .buttonStyle(TileButtonStyle())
                        .disabled(photoSave == .saving || photoSave == .saved)
                        .accessibilityIdentifier("saveVideo")
                        if completionRoom == nil, let guest = setup.script.speakers.first(where: { $0.id != setup.characterID }) {
                            CoDubInvitationButton(source: SocialDubSource(video: video, setup: setup, takes: takes), account: account, guestCharacterId: guest.id, recipientId: nil, title: "Invite a friend", isWorking: $isInviting, isTile: true)
                                .accessibilityIdentifier("shareWithDubbyFriends")
                        }
                        ShareLink(item: video) {
                            Label("Share dub", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(TileButtonStyle())
                        .accessibilityIdentifier("shareDub")
                    }
                    Button("Done", action: onDone)
                        .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
                        .accessibilityIdentifier("doneDub")
                        .disabled(isCoDubUploading || isInviting)
                }
                .padding(16)
                .background(Palette.background)
            }
        }
        .overlay {
            StateCarriers(items: [StateCarrier(identifier: "exportStatus", value: phase.stateValue)]
                + (phase.savedValue.map { [StateCarrier(identifier: "savedStatus", value: $0)] } ?? [])
                + (saveFailed ? [StateCarrier(identifier: "savedStatus", value: "failed")] : []))
        }
        .onAppear {
            if exportTask == nil {
                startExport()
            }
        }
        .onDisappear { exportTask?.cancel() }
        .interactiveDismissDisabled(isInviting)
        .alert("Couldn't save the video", isPresented: Binding(get: { photoSave.failure != nil }, set: { if !$0 { photoSave = .idle } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photoSave.failure ?? "")
        }
    }

    private var progressTitle: String {
        switch phase {
        case .filteringDialogue: "Filtering the original dialogue…"
        case .mixing: "Mixing your voice into the scene…"
        case .measuring: "Measuring your takes…"
        case .saving: "Saving to My Dubs…"
        case .finished, .cancelled, .failed: ""
        }
    }

    private func finished(video: URL) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("That’s a wrap")
                .dubFont(34, weight: .bold)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            ResultPlayer(url: video)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            if let completionRoom {
                CompleteCoDubView(room: completionRoom, video: video, linesRecorded: takes.count, account: account, isWorking: $isCoDubUploading)
            }
            WrapScore(state: scoringState, onRetry: retryScoring)
        }
    }

    private var scoringState: DubScoringModel.State? {
        guard let scoring else { return .notScored("This build has no backend, so dubs aren't scored.") }
        return savedDubID.flatMap { scoring.state(for: $0) }
    }

    private func retryScoring() {
        guard let savedDubID else { return }
        scoring?.retry(dubID: savedDubID)
    }

    private func saveToPhotos(_ video: URL) {
        photoSave = .saving
        Task {
            guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
                photoSave = .failed("Allow Dubby to add to your photos in Settings, then try again.")
                return
            }
            do {
                try await Self.addToPhotos(video)
                photoSave = .saved
            } catch {
                photoSave = .failed(error.localizedDescription)
            }
        }
    }

    /// Photos runs the change block on its own queue, so it must not inherit the view's main-actor isolation.
    nonisolated private static func addToPhotos(_ video: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: video)
        }
    }

    private func startExport() {
        exportTask?.cancel()
        attempt += 1
        saveFailed = false
        phase = .filteringDialogue
        let run = attempt
        exportTask = Task { await export(run: run) }
    }

    /// Stops the export and shows it as cancelled at once; the running work unwinds and removes its partial files.
    private func cancelExport() {
        exportTask?.cancel()
        phase = .cancelled
    }

    /// Moves to the next phase unless the export was cancelled, so a cancelled run can't overwrite the cancelled state.
    private func advance(to next: ExportPhase) async throws {
        try Task.checkCancellation()
        phase = next
        if let delay = LaunchConfiguration.current.exportStepDelayMilliseconds {
            try await Task.sleep(for: .milliseconds(delay))
        }
        try Task.checkCancellation()
    }

    private func export(run: Int) async {
        let section = setup.section
        let placements = ScriptBuilder.takePlacements(
            lines: setup.script.lines,
            takes: takes,
            sectionDuration: section.duration,
            grace: DubTiming.lineGrace
        )
        let spans = SocialAudioProtection.subtract(setup.protectedAudioSpans, from: ScriptBuilder.suppressionSpans(placements: placements, padding: DubTiming.suppressionPadding, sectionDuration: section.duration))
        let folder = setup.clip.workingDirectory
        let sceneAudio = folder.appending(path: "mix-scene-\(run).m4a")
        let background = folder.appending(path: "mix-background-\(run).caf")
        let output = folder.appending(path: "dub-\(run).mp4")
        do {
            if let curated = setup.curated {
                try await advance(to: .mixing)
                let timeline = DubTimeline.curated(selection: curated, takes: takes, rules: .standard)
                _ = try await DubProduction.render(timeline, to: output)
            } else {
            try await advance(to: .filteringDialogue)
            try await MediaPipeline.exportAudio(from: setup.clip.url, section: section, to: sceneAudio)
            try await MediaPipeline.renderDialogueSuppressed(from: sceneAudio, to: background)

            try await advance(to: .mixing)
            try await MediaPipeline.exportDub(
                source: setup.clip.url,
                section: section,
                dialogueSuppressed: background,
                placements: placements,
                suppressionSpans: spans,
                to: output
            )
            }

            try await advance(to: .measuring)
            var measurements: [TakeMeasurement] = []
            for line in setup.script.lines.sorted(by: { $0.start < $1.start }) {
                guard let take = takes[line.id] else { continue }
                measurements.append(await TakeMeasuring.measure(take: take, line: line, lines: setup.script.lines, sectionDuration: section.duration))
            }

            // Saving can't be cancelled, so a dub is either fully saved or not saved at all.
            try await advance(to: .saving)
            let id = UUID()
            let dub = SavedDub(
                id: id,
                sceneTitle: setup.clip.title,
                characterName: setup.script.speaker(withID: setup.characterID)?.name ?? "Unnamed character",
                linesDubbed: takes.count,
                totalLines: setup.script.lines(spokenBy: setup.characterID).count,
                sceneSeconds: section.duration,
                createdAt: .now,
                videoFileName: "\(id.uuidString).mp4",
                takeMeasurements: measurements,
                ownerUsername: account.username,
                coDub: try completionRoom.map { try SavedCoDub(room: $0) }
            )
            do {
                _ = try await history.save(video: output, as: dub)
            } catch {
                saveFailed = true
                throw error
            }
            savedDubID = id
            // Converts the takes for upload while they're on disk; sending and scoring continue in the background.
            await scoring?.submit(dubID: id, setup: setup, takes: takes)
            phase = .finished(
                video: history.videoURL(for: dub),
                trimmed: placements.filter { $0.trimmedSeconds > DubTiming.noticeableTrim },
                measurements: measurements
            )
        } catch {
            removePartialFiles([sceneAudio, background, output])
            // A newer run owns the screen now; only the latest run may report.
            guard run == attempt else { return }
            if Task.isCancelled || error is CancellationError {
                phase = .cancelled
            } else {
                phase = .failed(FlowIssue(error: error))
            }
        }
    }

    private func removePartialFiles(_ urls: [URL]) {
        for url in urls where FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                Self.logger.warning("Couldn't remove a partial export file: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private struct ResultPlayer: View {
    let url: URL
    @State private var player: AVPlayer
    @State private var isReady = false

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { player.play() }
            .onDisappear { player.pause() }
            .accessibilityLabel("Your dubbed scene")
            .accessibilityIdentifier("resultPlayer")
            .accessibilityValue(isReady ? "ready" : "loading")
            .task {
                do {
                    isReady = try await AVURLAsset(url: url).load(.isPlayable)
                } catch {
                    isReady = false
                }
            }
    }
}

private enum PhotoSave: Equatable {
    case idle
    case saving
    case saved
    case failed(String)

    var title: String {
        switch self {
        case .idle, .failed: "Save video"
        case .saving: "Saving…"
        case .saved: "Saved"
        }
    }

    var systemImage: String {
        self == .saved ? "checkmark" : "arrow.down.to.line"
    }

    var failure: String? {
        if case .failed(let message) = self { message } else { nil }
    }
}

/// The dub score and one sentence on what it means, or where scoring has got to.
private struct WrapScore: View {
    let state: DubScoringModel.State?
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case nil, .uploading, .scoring:
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(Palette.accentText)
                    Text("Scoring your dub…")
                        .dubFont(15, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                }
            case .complete(let sheet):
                if let score = sheet.dubScore {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(Int(score))")
                            .dubFont(56, weight: .bold)
                            .foregroundStyle(Palette.textPrimary)
                            .monospacedDigit()
                        Text("out of 100")
                            .dubFont(15, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("dubScore")
                    Text(DubScoreVerdict.sentence(for: score))
                        .dubFont(17, weight: .medium)
                        .foregroundStyle(Palette.textPrimary)
                } else {
                    Text("None of your lines could be scored. Try recording a little louder.")
                        .dubFont(15, weight: .regular)
                        .foregroundStyle(Palette.textSecondary)
                }
            case .failed(let message):
                Text(message)
                    .dubFont(15, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
                Button("Try scoring again", action: onRetry)
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("retryScoring")
            case .notScored(let reason):
                Text(reason)
                    .dubFont(15, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("dubScoreCard")
    }
}

/// One sentence on what a dub score means.
nonisolated enum DubScoreVerdict {
    static func sentence(for score: Double) -> String {
        switch score {
        case 90...: "Screen-ready. You nailed this scene."
        case 75..<90: "Strong dub. A few lines away from perfect."
        case 55..<75: "Solid start. Tighten your timing to score higher."
        default: "There's room for improvement. Give the scene another go."
        }
    }
}
