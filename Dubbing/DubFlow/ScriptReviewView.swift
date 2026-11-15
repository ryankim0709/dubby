import Speech
import SwiftUI

private enum AnalysisPhase: Equatable {
    case extractingAudio
    case preparingModel
    case transcribing
    case groupingVoices
    case ready(LineAnalysis)
    case failed(FlowIssue)

    var stateValue: String {
        switch self {
        case .extractingAudio: "extractingAudio"
        case .preparingModel: "preparingModel"
        case .transcribing: "transcribing"
        case .groupingVoices: "groupingVoices"
        case .ready: "ready"
        case .failed: "failed"
        }
    }

    var stepIndex: Int {
        switch self {
        case .extractingAudio: 0
        case .preparingModel: 1
        case .transcribing: 2
        case .groupingVoices: 3
        case .ready, .failed: 4
        }
    }
}

/// Transcribes the scene and splits it into lines, then hands off to the script editor.
struct ScriptReviewView: View {
    let request: TranscriptionRequest
    let onStart: (DubSetup) -> Void
    @State private var phase: AnalysisPhase = .extractingAudio
    @State private var attempt = 0

    var body: some View {
        Group {
            switch phase {
            case .ready(let analysis):
                ScriptEditor(request: request, analysis: analysis, onStart: onStart)
            case .failed(let issue):
                failure(issue)
            case .extractingAudio, .preparingModel, .transcribing, .groupingVoices:
                progress
            }
        }
        .screenBackground()
        .navigationTitle("Your scene")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { StateCarriers(items: [StateCarrier(identifier: "transcribeProgress", value: phase.stateValue)]) }
        .task(id: attempt) { await analyze() }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Building your script")
                .dubFont(32, weight: .bold)
                .foregroundStyle(Palette.textPrimary)
            VStack(alignment: .leading, spacing: 16) {
                stepRow(index: 0, title: "Pulling the scene's audio")
                #if targetEnvironment(simulator)
                stepRow(index: 1, title: "Preparing library transcription")
                #else
                stepRow(index: 1, title: "Getting the \(request.language.name) speech model")
                #endif
                stepRow(index: 2, title: "Transcribing the dialogue")
                stepRow(index: 3, title: "Splitting lines by voice")
            }
            .padding(16)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Building your script")
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func stepRow(index: Int, title: String) -> some View {
        HStack(spacing: 12) {
            Group {
                if index < phase.stepIndex {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.accent)
                } else if index == phase.stepIndex {
                    ProgressView()
                        .tint(Palette.accentText)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(Palette.track)
                }
            }
            .dubFont(18, weight: .regular)
            .frame(width: 24)
            Text(title)
                .dubFont(16, weight: index == phase.stepIndex ? .medium : .regular)
                .foregroundStyle(index <= phase.stepIndex ? Palette.textPrimary : Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var speechPermissionValue: String {
        SFSpeechRecognizer.authorizationStatus() == .restricted ? "restricted" : "denied"
    }

    private func failure(_ issue: FlowIssue) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            IssueCard(
                title: issue.opensSettings ? "Speech recognition is off" : "The script couldn't be built",
                issue: issue,
                identifier: issue.opensSettings ? "speechPermissionNotice" : "transcribeError",
                value: issue.opensSettings ? speechPermissionValue : issue.code,
                retryTitle: "Try again",
                retryIdentifier: "transcribeRetry",
                retry: { attempt += 1 }
            )
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func analyze() async {
        do {
            phase = .extractingAudio
            let audioURL = request.clip.workingDirectory.appending(path: "scene.m4a")
            try await MediaPipeline.exportAudio(from: request.clip.url, section: request.section, to: audioURL)
            phase = .preparingModel
            #if targetEnvironment(simulator)
            let transcriber = try SceneTranscriptionClient.configured(in: .main)
            phase = .transcribing
            let words = try await transcriber.transcribe(request)
            #else
            let transcriber = try await SpeechTranscription.prepare(for: request.language)
            phase = .transcribing
            let words = try await SpeechTranscription.transcribe(audioURL: audioURL, using: transcriber)
            #endif
            try Task.checkCancellation()
            let lines = ScriptBuilder.segmentLines(words: words, pauseThreshold: 0.7, sentencePause: 0)
            guard !lines.isEmpty else { throw DubFlowError.noSpeechFound }
            phase = .groupingVoices
            phase = .ready(try await MediaPipeline.analyzeVoices(audioURL: audioURL, lines: lines, barCount: 48))
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(FlowIssue(error: error))
        }
    }
}

private struct ScriptEditor: View {
    let request: TranscriptionRequest
    let analysis: LineAnalysis
    let onStart: (DubSetup) -> Void
    @State private var speakerCount: Int
    @State private var script: Script
    @State private var characterID = 0
    @State private var renamingSpeaker: Speaker?
    @State private var draftName = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(request: TranscriptionRequest, analysis: LineAnalysis, onStart: @escaping (DubSetup) -> Void) {
        self.request = request
        self.analysis = analysis
        self.onStart = onStart
        let speakerCount = 2
        _speakerCount = State(initialValue: speakerCount)
        _script = State(initialValue: ScriptBuilder.buildScript(analysis: analysis, speakerCount: speakerCount, names: []))
    }

    private var characterLines: [ScriptLine] { script.lines(spokenBy: characterID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose your role")
                    .dubFont(32, weight: .bold)
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("\(request.clip.title) · \(request.section.duration.preciseClockString)")
                    .dubFont(15, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
                LazyVGrid(columns: adaptiveGridColumns(spacing: 14, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize), spacing: 14) {
                    ForEach(script.speakers) { speaker in
                        characterCard(speaker)
                    }
                }
                DisclosureGroup {
                    speakersCard
                    VStack(spacing: 8) {
                        ForEach(script.lines) { line in
                            ScriptLineRow(line: line, speakers: script.speakers) { speakerID in
                                script = script.reassigning(lineID: line.id, to: speakerID)
                            }
                        }
                    }
                } label: {
                    Label("Review dialogue and voices", systemImage: "text.alignleft")
                        .dubFont(17, weight: .semibold)
                        .foregroundStyle(Palette.textPrimary)
                        .frame(minHeight: 44)
                }
                .tint(Palette.textSecondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .containerIdentifier("scriptScreen")
        }
        .scrollIndicators(.hidden)
        // Pinned so the primary action stays on screen beside a long script.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Dub as \(script.speaker(withID: characterID)?.name ?? "this character")") {
                onStart(DubSetup(clip: request.clip, section: request.section, script: script, characterID: characterID))
            }
            .buttonStyle(PrimaryButtonStyle(cornerRadius: 16))
            .disabled(characterLines.isEmpty)
            .opacity(characterLines.isEmpty ? 0.5 : 1)
            .accessibilityIdentifier("startDubbing")
            .padding(16)
            .background(Palette.background)
        }
        .onChange(of: speakerCount) { _, count in
            script = ScriptBuilder.buildScript(analysis: analysis, speakerCount: count, names: script.speakers.map(\.name))
            characterID = min(characterID, count - 1)
        }
        .alert("Rename speaker", isPresented: Binding(get: { renamingSpeaker != nil }, set: { if !$0 { renamingSpeaker = nil } })) {
            TextField("Character name", text: $draftName)
            Button("Save") {
                let name = draftName.trimmingCharacters(in: .whitespaces)
                if let speaker = renamingSpeaker, !name.isEmpty {
                    script = script.renaming(speakerID: speaker.id, to: name)
                }
                renamingSpeaker = nil
            }
            Button("Cancel", role: .cancel) { renamingSpeaker = nil }
        }
    }

    private var speakersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            AdaptiveStack(rowAlignment: .center, spacing: 8) {
                Text("Voices in this scene")
                    .dubFont(16, weight: .medium)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Stepper("\(speakerCount)", value: $speakerCount, in: 1...4)
                    .dubFont(16, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize()
                    .accessibilityLabel("Voices in this scene")
                    .accessibilityValue("\(speakerCount)")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(script.speakers) { speaker in
                        Button {
                            draftName = speaker.name
                            renamingSpeaker = speaker
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Palette.speakerColor(speaker.id))
                                    .frame(width: 10, height: 10)
                                Text(speaker.name)
                                    .dubFont(14, weight: .medium)
                                Image(systemName: "pencil")
                                    .dubFont(12, weight: .regular)
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            .foregroundStyle(Palette.textPrimary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(Palette.background, in: Capsule())
                        }
                        .accessibilityLabel("Rename \(speaker.name)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            Text("Voices are grouped by how they sound, so similar voices or loud music can mix them up. Tap a line's name to fix it.")
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func characterCard(_ speaker: Speaker) -> some View {
        let lines = script.lines(spokenBy: speaker.id)
        let seconds = lines.reduce(0) { $0 + $1.duration }
        let isSelected = speaker.id == characterID
        let previewTime = request.section.start + (lines.first.map { $0.start + $0.duration / 2 } ?? 0)
        return Button {
            characterID = speaker.id
        } label: {
            VideoThumbnail(url: request.clip.url, time: previewTime)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .center, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(speaker.name.uppercased())
                            .displayFont(34)
                            .foregroundStyle(Palette.textPrimary)
                        Text("\(lines.count) lines · \(Int(seconds.rounded())) sec")
                            .dubFont(13, weight: .medium)
                            .foregroundStyle(Palette.textPrimary)
                    }
                    .padding(14)
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Palette.onAccent, Palette.accent)
                            .padding(12)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card)
                        .strokeBorder(isSelected ? Palette.accent : Palette.hairline, lineWidth: isSelected ? 2 : 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(speaker.name), \(lines.count) lines, \(Int(seconds.rounded())) seconds")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("characterCard-\(speaker.id)")
    }
}

private struct ScriptLineRow: View {
    let line: ScriptLine
    let speakers: [Speaker]
    let onAssign: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    ForEach(speakers) { speaker in
                        Button(speaker.name) { onAssign(speaker.id) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(speakers.first { $0.id == line.speakerID }?.name ?? "Speaker")
                            .dubFont(12, weight: .semibold)
                        Image(systemName: "chevron.down")
                            .dubFont(10, weight: .semibold)
                    }
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(Palette.speakerColor(line.speakerID), in: Capsule())
                }
                .accessibilityLabel("Speaker for this line")
                Spacer()
                Text("\(line.start.preciseClockString) – \(line.end.preciseClockString)")
                    .dubFont(12, weight: .regular)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
            }
            Text(line.text)
                .dubFont(16, weight: .regular)
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .containerIdentifier("scriptLine-\(line.id)")
        .accessibilityValue("\(line.speakerID)")
    }
}
