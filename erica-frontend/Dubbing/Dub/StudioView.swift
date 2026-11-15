import AVFoundation
import Combine
import SwiftUI

struct StudioView: View {
    let partner: Friend?
    let onWrap: (DubSummary) -> Void
    @State private var engine: StudioEngine
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.homeLanguage) private var homeLanguage: HomeLanguage = .chinese
    @AppStorage(SettingsKey.learningMode) private var learningMode = true
    @AppStorage(SettingsKey.coachAfterTake) private var coachAfterTake = true
    @State private var isShowingTutor = false

    /// The language to show meanings in, or nil when learning aids are off or not needed for this scene.
    private var aidLanguage: HomeLanguage? {
        learningMode && engine.scene.needsTranslation(for: homeLanguage) ? homeLanguage : nil
    }

    init(scene: SceneClip, character: SceneCharacter, partner: Friend?, onWrap: @escaping (DubSummary) -> Void) {
        self.partner = partner
        self.onWrap = onWrap
        _engine = State(initialValue: StudioEngine(scene: scene, character: character))
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioStage(engine: engine, partner: partner, aidLanguage: aidLanguage)
            switch engine.phase {
            case .loading:
                ProgressView()
                    .tint(Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let error):
                ContentUnavailableView("Can't open this scene", systemImage: "film.stack", description: Text(error.message))
                    .frame(maxHeight: .infinity)
            default:
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        LineProgressStrip(engine: engine)
                        ScriptContext(engine: engine, partner: partner, aidLanguage: aidLanguage)
                        TakeComparison(engine: engine)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    bottomDeck
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .background(Palette.background)
                }
            }
        }
        .screenBackground()
        .navigationTitle(engine.character.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Language learning", isOn: $learningMode)
                    Picker("Home language", selection: $homeLanguage) {
                        ForEach(HomeLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .disabled(!learningMode)
                    Toggle("Character coach", isOn: $coachAfterTake)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Studio settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if engine.hasAnyAccepted {
                    Button {
                        Task { await engine.watchScene() }
                    } label: {
                        Image(systemName: "film")
                    }
                    .accessibilityLabel("Watch the scene so far")
                    .disabled(engine.phase == .recording)
                }
            }
        }
        .task { await engine.prepare() }
        // Keeping the last line hands over to the tutor for a pronunciation pass.
        .onChange(of: engine.isComplete) { _, isComplete in
            if isComplete { isShowingTutor = true }
        }
        .fullScreenCover(isPresented: $isShowingTutor) {
            TutorTakeoverView(
                character: engine.character,
                lines: engine.myLines,
                report: TutorReport.sample(character: engine.character, lines: engine.myLines),
                onPractice: { line in
                    isShowingTutor = false
                    if let index = engine.myLines.firstIndex(of: line) {
                        engine.select(lineAt: index)
                    }
                },
                onContinue: {
                    isShowingTutor = false
                    onWrap(engine.summary(partner: partner))
                }
            )
        }
        // Pushing the wrap screen also fires this, so only stop playback and capture here; the
        // engine cleans up its takes when the whole flow closes.
        .onDisappear { engine.stop() }
        // Only leaving the app stops a take. `.inactive` also fires for system prompts like the
        // microphone permission alert, which used to cancel the very take it was asking about.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background { engine.stop() }
        }
        // React to an interruption starting (a call, Siri), not to the "ended" notice that follows.
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began {
                engine.stop()
            }
        }
        .alert("Couldn't record", isPresented: isShowingAlert, presenting: engine.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
        .animation(.spring(duration: 0.4, bounce: 0.15), value: engine.phase)
    }

    private var isShowingAlert: Binding<Bool> {
        Binding(
            get: { engine.alert != nil },
            set: { isPresented in
                if !isPresented { engine.alert = nil }
            }
        )
    }

    @ViewBuilder
    private var bottomDeck: some View {
        if engine.phase == .reviewing, let result = engine.pending {
            if coachAfterTake {
                HologramCoachPanel(
                    character: engine.character,
                    line: engine.currentLine,
                    result: result,
                    onReplayTake: { Task { await engine.playMine() } },
                    onRetry: { Task { await engine.retry() } },
                    onKeep: { engine.keep() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                TakeReviewBar(
                    result: result,
                    onReplayTake: { Task { await engine.playMine() } },
                    onRetry: { Task { await engine.retry() } },
                    onKeep: { engine.keep() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        } else if engine.isComplete && !engine.isBusy {
            VStack(spacing: 10) {
                Button("Wrap and export") {
                    onWrap(engine.summary(partner: partner))
                }
                .buttonStyle(PrimaryButtonStyle())
                Button {
                    isShowingTutor = true
                } label: {
                    Label("Pronunciation tutor", systemImage: "person.wave.2.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("Watch the whole scene") {
                    Task { await engine.watchScene() }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 8)
        } else {
            RecordDeck(engine: engine)
        }
    }
}

// MARK: - Stage

/// The scene in picture, with the state badge, count-in, and live subtitles over it.
private struct StudioStage: View {
    let engine: StudioEngine
    let partner: Friend?
    let aidLanguage: HomeLanguage?

    var body: some View {
        PlayerSurface(player: engine.player, gravity: .resizeAspectFill)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                StateBadge(phase: engine.phase)
                    .padding(12)
            }
            .overlay {
                if let count = countIn {
                    Text("\(count)")
                        .dubFont(84, weight: .heavy)
                        .foregroundStyle(Palette.textPrimary)
                        .shadow(color: .black.opacity(0.6), radius: 12, y: 4)
                        .contentTransition(.numericText(countsDown: true))
                        .accessibilityLabel("Starting in \(count)")
                }
            }
            .overlay(alignment: .bottom) {
                if let line = subtitleLine {
                    Subtitle(
                        line: line,
                        speaker: speakerName(for: line),
                        isMine: line.characterID == engine.character.id,
                        progress: progress(through: line),
                        translation: aidLanguage.flatMap { engine.scene.translation(of: line, into: $0) }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
            .background(.black)
    }

    private var countIn: Int? {
        guard engine.phase == .recording else { return nil }
        let remaining = engine.currentLine.start - engine.playhead
        guard remaining > 0.05 else { return nil }
        return Int(remaining.rounded(.up))
    }

    private var subtitleLine: ScriptLine? {
        guard engine.isBusy else { return nil }
        return engine.scene.lines.first { engine.playhead >= $0.start - 0.1 && engine.playhead <= $0.end + 0.25 }
    }

    private func speakerName(for line: ScriptLine) -> String {
        if line.characterID == engine.character.id { return "You" }
        let name = engine.scene.character(id: line.characterID)?.name ?? ""
        if let partner { return "\(partner.name) as \(name)" }
        return name
    }

    private func progress(through line: ScriptLine) -> Double {
        min(1, max(0, (engine.playhead - line.start) / (line.end - line.start)))
    }
}

private struct StateBadge: View {
    let phase: StudioPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let label {
            HStack(spacing: 6) {
                if phase == .recording {
                    Circle()
                        .fill(Palette.record)
                        .frame(width: 8, height: 8)
                        .phaseAnimator([1.0, 0.3]) { dot, opacity in
                            dot.opacity(reduceMotion ? 1 : opacity)
                        } animation: { _ in .easeInOut(duration: 0.6) }
                }
                Text(label.title)
                    .dubFont(12, weight: .bold)
                    .tracking(0.6)
            }
            .foregroundStyle(label.tint)
            .padding(.horizontal, 10)
            .frame(minHeight: 26)
            .background(.black.opacity(0.55), in: Capsule())
        }
    }

    private var label: (title: String, tint: Color)? {
        switch phase {
        case .listening: ("ORIGINAL", Palette.textPrimary)
        case .recording: ("REC", Palette.record)
        case .replaying: ("YOUR TAKE", Palette.accent)
        case .watchingScene: ("YOUR SCENE", Palette.accent)
        default: nil
        }
    }
}

/// Subtitle with a karaoke wipe on the user's own lines, so the pace of the original is visible.
private struct Subtitle: View {
    let line: ScriptLine
    let speaker: String
    let isMine: Bool
    let progress: Double
    let translation: String?

    var body: some View {
        VStack(spacing: 2) {
            Text(speaker)
                .dubFont(12, weight: .semibold)
                .foregroundStyle(isMine ? Palette.textPrimary : Palette.textSecondary)
            Text(line.text)
                .dubFont(17, weight: .semibold)
                .foregroundStyle(isMine ? Palette.placeholder : Palette.textPrimary)
                .overlay(alignment: .leading) {
                    if isMine {
                        Text(line.text)
                            .dubFont(17, weight: .semibold)
                            .foregroundStyle(Palette.textPrimary)
                            .mask(alignment: .leading) {
                                GeometryReader { proxy in
                                    Rectangle().frame(width: proxy.size.width * progress)
                                }
                            }
                    }
                }
                .multilineTextAlignment(.center)
            if let translation {
                Text(translation)
                    .dubFont(14, weight: .medium)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Line progress

private struct LineProgressStrip: View {
    let engine: StudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Line \(engine.currentIndex + 1) of \(engine.myLines.count)")
                    .dubFont(15, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Text("\(engine.accepted.count) kept")
                    .dubFont(15, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                ForEach(Array(engine.myLines.enumerated()), id: \.element.id) { index, line in
                    Button {
                        engine.select(lineAt: index)
                    } label: {
                        Capsule()
                            .fill(fill(for: line, at: index))
                            .frame(height: 5)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(engine.isBusy)
                    .accessibilityLabel("Line \(index + 1)\(engine.accepted[line.id] == nil ? "" : ", kept")")
                }
            }
        }
    }

    private func fill(for line: ScriptLine, at index: Int) -> Color {
        if engine.accepted[line.id] != nil { return Palette.accent }
        if index == engine.currentIndex { return Palette.textSecondary }
        return Palette.track
    }
}

// MARK: - Script

/// The current line with its neighbours, so the user knows what they're answering and what comes next.
private struct ScriptContext: View {
    let engine: StudioEngine
    let partner: Friend?
    let aidLanguage: HomeLanguage?

    var body: some View {
        let lines = engine.scene.lines
        let index = lines.firstIndex(of: engine.currentLine) ?? 0
        VStack(alignment: .leading, spacing: 14) {
            if index > 0 {
                neighbour(lines[index - 1])
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("You · \(engine.character.name)")
                    .dubFont(13, weight: .semibold)
                    .foregroundStyle(Palette.textSecondary)
                if let aidLanguage {
                    GlossedLine(text: engine.currentLine.text, scene: engine.scene, language: aidLanguage, fontSize: 26)
                    if let translation = engine.scene.translation(of: engine.currentLine, into: aidLanguage) {
                        Text(translation)
                            .dubFont(17, weight: .medium)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(engine.currentLine.text)
                        .dubFont(26, weight: .bold)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if index + 1 < lines.count {
                neighbour(lines[index + 1])
            }
        }
    }

    private func neighbour(_ line: ScriptLine) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name(for: line))
                .dubFont(12, weight: .semibold)
                .foregroundStyle(Palette.placeholder)
            Text(line.text)
                .dubFont(15, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
            if let aidLanguage, let translation = engine.scene.translation(of: line, into: aidLanguage) {
                Text(translation)
                    .dubFont(13, weight: .regular)
                    .foregroundStyle(Palette.placeholder)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func name(for line: ScriptLine) -> String {
        if line.characterID == engine.character.id { return "You" }
        let name = engine.scene.character(id: line.characterID)?.name ?? ""
        if let partner { return "\(partner.name) as \(name)" }
        return name
    }
}

// MARK: - Waveforms

/// The original line and the user's take on one time axis with a shared playhead, so the user
/// can see where they came in early, late, or long.
private struct TakeComparison: View {
    let engine: StudioEngine

    var body: some View {
        let line = engine.currentLine
        let window = engine.window(for: line)
        let result = engine.currentResult
        VStack(alignment: .leading, spacing: 10) {
            waveformRow(title: engine.character.name, tint: Palette.textSecondary) {
                WaveformTrack(
                    source: .file(engine.originalEnvelope, startsAt: 0),
                    window: window,
                    highlight: line.start...line.end
                )
            }
            waveformRow(title: "You", tint: Palette.accent) {
                if engine.phase == .recording {
                    WaveformTrack(source: .live(engine.liveLevels), window: window, highlight: line.start...line.end)
                } else if let result {
                    WaveformTrack(source: .file(result.envelope, startsAt: result.take.sceneStart), window: window, highlight: line.start...line.end)
                } else {
                    Text("Record to see your take here")
                        .dubFont(13, weight: .regular)
                        .foregroundStyle(Palette.placeholder)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay {
            GeometryReader { proxy in
                if engine.isBusy, window.contains(engine.playhead) {
                    let inset: CGFloat = 12 + 64
                    let width = proxy.size.width - inset - 12
                    let x = inset + width * (engine.playhead - window.lowerBound) / (window.upperBound - window.lowerBound)
                    Rectangle()
                        .fill(Palette.textPrimary)
                        .frame(width: 1.5, height: proxy.size.height - 16)
                        .position(x: x, y: proxy.size.height / 2)
                }
            }
            .allowsHitTesting(false)
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary(result: result))
    }

    private func waveformRow<Track: View>(title: String, tint: Color, @ViewBuilder track: () -> Track) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .dubFont(12, weight: .semibold)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .frame(width: 64, alignment: .leading)
            track()
                .foregroundStyle(tint)
                .frame(height: 44)
        }
    }

    private func accessibilitySummary(result: LineResult?) -> String {
        guard let result else { return "Waveform of the original line. No take recorded yet." }
        return "Waveforms of the original line and your take. \(CoachScript.verdictLabel(for: result.timing))."
    }
}

private struct WaveformTrack: View {
    enum Source {
        case file(Envelope?, startsAt: Double)
        case live([LevelSample])
    }

    let source: Source
    let window: ClosedRange<Double>
    let highlight: ClosedRange<Double>

    var body: some View {
        Canvas { context, size in
            let barWidth: CGFloat = 2.5
            let spacing: CGFloat = 1.5
            let count = max(1, Int(size.width / (barWidth + spacing)))
            let span = window.upperBound - window.lowerBound
            let levels = (0..<count).map { index in
                level(at: window.lowerBound + span * (Double(index) + 0.5) / Double(count))
            }
            let peak = max(levels.compactMap { $0 }.max() ?? 0, 0.02)
            for (index, value) in levels.enumerated() {
                guard let value else { continue }
                let time = window.lowerBound + span * (Double(index) + 0.5) / Double(count)
                let height = max(2, size.height * CGFloat(value / peak))
                let rect = CGRect(
                    x: CGFloat(index) * (barWidth + spacing),
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                let opacity = highlight.contains(time) ? 1.0 : 0.35
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .style(.foreground.opacity(opacity)))
            }
        }
    }

    private func level(at time: Double) -> Float? {
        switch source {
        case .file(let envelope, let start):
            return envelope?.value(at: time - start)
        case .live(let samples):
            guard let last = samples.last, time <= last.time else { return nil }
            return samples.last { $0.time <= time }?.level ?? 0
        }
    }
}

// MARK: - Record deck

private struct RecordDeck: View {
    let engine: StudioEngine

    var body: some View {
        HStack(alignment: .top) {
            deckButton(
                title: engine.phase == .listening ? "Stop" : "Original",
                systemImage: engine.phase == .listening ? "stop.fill" : "play.fill",
                isEnabled: engine.phase != .recording
            ) {
                if engine.phase == .listening {
                    engine.stop()
                } else {
                    Task { await engine.listen() }
                }
            }
            Spacer()
            VStack(spacing: 8) {
                Button {
                    if engine.phase == .recording {
                        engine.stop()
                    } else {
                        Task { await engine.record() }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(Palette.record.opacity(0.5), lineWidth: 3)
                        if engine.phase == .recording {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Palette.record)
                                .frame(width: 28, height: 28)
                        } else {
                            Circle()
                                .fill(Palette.record)
                                .padding(8)
                        }
                    }
                    .frame(width: 84, height: 84)
                }
                .accessibilityLabel(engine.phase == .recording ? "Cancel recording" : "Record line \(engine.currentIndex + 1)")
                Text(engine.phase == .recording ? "Cancel" : (engine.currentResult == nil ? "Record" : "Record again"))
                    .dubFont(13, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
            }
            Spacer()
            deckButton(
                title: engine.phase == .replaying ? "Stop" : "Your take",
                systemImage: engine.phase == .replaying ? "stop.fill" : "play.fill",
                isEnabled: engine.currentResult != nil && engine.phase != .recording
            ) {
                if engine.phase == .replaying {
                    engine.stop()
                } else {
                    Task { await engine.playMine() }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private func deckButton(title: String, systemImage: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 60, height: 60)
                    .background(Palette.surfaceRaised, in: Circle())
            }
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.4)
            .accessibilityLabel(title)
            Text(title)
                .dubFont(13, weight: .semibold)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)
        }
        .frame(minWidth: 84)
        .padding(.top, 12)
    }
}
