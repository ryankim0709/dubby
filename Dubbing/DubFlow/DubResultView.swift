import AVKit
import SwiftUI

private enum ExportPhase: Equatable {
    case filteringDialogue
    case mixing
    case measuring
    case saving
    case finished(video: URL, trimmed: [TakePlacement], measurements: [TakeMeasurement])
    case failed(FlowIssue)
}

/// Mixes the takes into the scene, saves the dub to the library, and shows it.
struct DubResultView: View {
    let setup: DubSetup
    let takes: [Int: RecordedTake]
    let onDone: () -> Void
    @State private var phase: ExportPhase = .filteringDialogue
    @State private var attempt = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BackHeader(title: "Your dub") { EmptyView() }
                    .padding(.top, 8)
                switch phase {
                case .filteringDialogue, .mixing, .measuring, .saving:
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
                case .failed(let issue):
                    IssueCard(title: "The dub couldn't be exported", issue: issue, retry: { attempt += 1 })
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .background(Palette.background)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: attempt) { await export() }
    }

    private var progressTitle: String {
        switch phase {
        case .filteringDialogue: "Filtering the original dialogue…"
        case .mixing: "Mixing your voice into the scene…"
        case .measuring: "Measuring your takes…"
        case .saving: "Saving to My Dubs…"
        case .finished, .failed: ""
        }
    }

    private func finished(video: URL, trimmed: [TakePlacement], measurements: [TakeMeasurement]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ResultPlayer(url: video)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Text("You're the main character.")
                .dubFont(20, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
            Text("\(takes.count) of \(setup.script.lines(spokenBy: setup.characterID).count) lines in your voice, saved to My Dubs.")
                .dubFont(14, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
            Label(
                "Under your lines the original dialogue is filtered out rather than separated, so music and effects there sound thinner.",
                systemImage: "waveform.badge.minus"
            )
            .dubFont(12, weight: .regular)
            .foregroundStyle(Palette.textSecondary)
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
            TakeSummaryView(measurements: measurements)
            ShareLink(item: video) {
                Label("Share dub", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryButtonStyle(cornerRadius: 16))
            .accessibilityIdentifier("shareDub")
            Button("Done", action: onDone)
                .buttonStyle(OutlineCapsuleButtonStyle())
                .frame(maxWidth: .infinity)
        }
    }

    private func export() async {
        let section = setup.section
        let placements = ScriptBuilder.takePlacements(
            lines: setup.script.lines,
            takes: takes,
            sectionDuration: section.duration,
            grace: DubTiming.lineGrace
        )
        let spans = ScriptBuilder.suppressionSpans(placements: placements, padding: DubTiming.suppressionPadding, sectionDuration: section.duration)
        let folder = setup.clip.workingDirectory
        do {
            phase = .filteringDialogue
            let sceneAudio = folder.appending(path: "mix-scene.m4a")
            let background = folder.appending(path: "mix-background.caf")
            try await MediaPipeline.exportAudio(from: setup.clip.url, section: section, to: sceneAudio)
            try await MediaPipeline.renderDialogueSuppressed(from: sceneAudio, to: background)

            phase = .mixing
            let output = folder.appending(path: "dub-\(attempt).mp4")
            try await MediaPipeline.exportDub(
                source: setup.clip.url,
                section: section,
                dialogueSuppressed: background,
                placements: placements,
                suppressionSpans: spans,
                to: output
            )

            phase = .measuring
            var measurements: [TakeMeasurement] = []
            for line in setup.script.lines.sorted(by: { $0.start < $1.start }) {
                guard let take = takes[line.id] else { continue }
                measurements.append(await TakeMeasuring.measure(take: take, line: line, lines: setup.script.lines, sectionDuration: section.duration))
            }

            phase = .saving
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
            _ = try DubLibrary.save(video: output, as: dub, in: DubLibrary.defaultFolder)
            phase = .finished(
                video: DubLibrary.videoURL(for: dub, in: DubLibrary.defaultFolder),
                trimmed: placements.filter { $0.trimmedSeconds > DubTiming.noticeableTrim },
                measurements: measurements
            )
        } catch {
            phase = .failed(FlowIssue(error: error))
        }
    }
}

private struct ResultPlayer: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { player.play() }
            .onDisappear { player.pause() }
            .accessibilityLabel("Your dubbed scene")
    }
}
