import AVKit
import os
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
    let onKeepRecording: () -> Void
    @State private var phase: ExportPhase = .filteringDialogue
    @State private var savedDubID: UUID?
    @State private var tutor: LiveTutorSession?
    @State private var tutorUnavailable: String?
    @State private var attempt = 0
    @State private var exportTask: Task<Void, Never>?
    @State private var saveFailed = false
    @State private var clubDraft: ClubMediaDraft?
    @State private var socialSource: SocialDubSource?
    @State private var isCoDubUploading = false
    @State private var returnsToStudio = false

    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "export")
    private let history = LocalDubHistory(folder: DubLibrary.defaultFolder)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                    .padding(.top, 8)
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
                case .finished(let video, let trimmed, let measurements):
                    finished(video: video, trimmed: trimmed, measurements: measurements)
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
            .padding(.bottom, 16)
            .containerIdentifier("exportScreen")
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        // Pinned so sharing and finishing stay reachable beside the measurements.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .finished(let video, _, _) = phase {
                VStack(spacing: 8) {
                    if completionRoom == nil {
                        Button("Invite a friend or post to feed", systemImage: "person.2") {
                            socialSource = SocialDubSource(video: video, setup: setup, takes: takes)
                        }
                        .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
                        .accessibilityIdentifier("shareWithDubbyFriends")
                    }
                    ShareLink(item: video) {
                        Label("Share dub", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("shareDub")
                    if setup.curated?.scene.id == "tears-of-steel-bridge" {
                        Button("Share to club") {
                            clubDraft = ClubMediaDraft(url: video, kind: .video, title: setup.clip.title, replyToMessageId: nil)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("shareResultToClub")
                    }
                    Button("Done", action: onDone)
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("doneDub")
                        .disabled(isCoDubUploading)
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
        .sheet(item: $socialSource, onDismiss: {
            if returnsToStudio {
                returnsToStudio = false
                onKeepRecording()
            }
        }) { source in
            SocialSharingView(source: source, account: account, onClose: { socialSource = nil }, onKeepRecording: {
                returnsToStudio = true
                socialSource = nil
            })
        }
        .sheet(item: $clubDraft) { draft in ClubComposer(account: account, draft: draft, onShared: {}) }
        .fullScreenCover(isPresented: Binding(get: { tutor != nil }, set: { if !$0 { tutor = nil } })) {
            if let tutor {
                LiveTutorView(session: tutor)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                exportTask?.cancel()
                onDone()
            } label: {
                Image(systemName: "arrow.left")
                    .dubFont(16, weight: .medium)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back")
            .accessibilityIdentifier("exportBack")
            .disabled(isCoDubUploading)
            Text("Your dub")
                .dubFont(16, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
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

    private func finished(video: URL, trimmed: [TakePlacement], measurements: [TakeMeasurement]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
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
            Text("You're the main character.")
                .dubFont(22, weight: .bold)
                .foregroundStyle(Palette.textPrimary)
            Text("\(takes.count) of \(setup.script.lines(spokenBy: setup.characterID).count) lines in your voice, saved to your Shelf.")
                .dubFont(14, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
            if setup.curated == nil { Label(
                "Under your lines the original dialogue is filtered out rather than separated, so music and effects there sound thinner.",
                systemImage: "waveform.badge.minus"
            )
            .dubFont(12, weight: .regular)
            .foregroundStyle(Palette.textSecondary)
            }
            if !trimmed.isEmpty {
                Label(
                    String(
                        format: "%d %@ ran into the next line and %@ cut by %.1f s in total.",
                        trimmed.count,
                        trimmed.count == 1 ? "take" : "takes",
                        trimmed.count == 1 ? "was" : "were",
                        trimmed.reduce(0) { $0 + $1.trimmedSeconds }
                    ),
                    systemImage: "scissors"
                )
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.streak)
                .accessibilityIdentifier("dubTrimNotice")
            }
            DubScoreCard(state: scoringState, onRetry: retryScoring, onPractise: startTutor)
            if let tutorUnavailable {
                Text(tutorUnavailable)
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.streak)
            }
            TakeSummaryView(measurements: measurements)
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

    /// The tutor reads the same dub the scoring model submitted, keyed by its lowercased id.
    private func startTutor() {
        guard let savedDubID else { return }
        do {
            let backend = try CoachBackendClient.configured(in: .main, tokens: AccountTokenProvider(account: account))
            tutorUnavailable = nil
            tutor = LiveTutorSession(clientDubID: savedDubID.uuidString.lowercased(), backend: backend)
        } catch {
            tutorUnavailable = error.localizedDescription
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
                takeMeasurements: measurements
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
