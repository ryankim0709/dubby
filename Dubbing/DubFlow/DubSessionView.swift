import AVFoundation
import Combine
import os
import SwiftUI

private enum SessionActivity: Equatable {
    case idle
    case playingOriginal
    case recording
    case playingTake
}

/// A take that was just recorded and waits for the user to keep it or record again. A kept take is never
/// replaced until a newer one is kept, so cancelling or abandoning a retry loses nothing.
private struct PendingTake {
    let lineID: Int
    let take: RecordedTake
    let measurement: TakeMeasurement
}

/// The real dubbing studio: hear each original line, then record yours along with the muted video.
struct DubSessionView: View {
    let setup: DubSetup
    let onFinish: ([Int: RecordedTake]) -> Void
    @State private var player: SegmentPlayer
    @State private var recorder = TakeRecorder()
    @State private var takePlayer = TakePlayer()
    @State private var index = 0
    /// Kept takes, by line.
    @State private var takes: [Int: RecordedTake] = [:]
    @State private var measurements: [Int: TakeMeasurement] = [:]
    @State private var pending: PendingTake?
    @State private var activity: SessionActivity = .idle
    @State private var activityTask: Task<Void, Never>?
    @State private var issue: FlowIssue?
    /// The activity that produced `issue`, so Try again repeats it.
    @State private var failedActivity: SessionActivity?
    @State private var microphone = MicrophoneAccess(AVAudioApplication.shared.recordPermission)
    @State private var isConfirmingExit = false
    @State private var isRecordingCancelled = false
    /// Why the current activity was cut short by the system, if it was; an interrupted recording isn't kept.
    @State private var interruption: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "studio")

    init(setup: DubSetup, onFinish: @escaping ([Int: RecordedTake]) -> Void) {
        self.setup = setup
        self.onFinish = onFinish
        _player = State(initialValue: SegmentPlayer(url: setup.clip.url))
    }

    private var lines: [ScriptLine] { setup.script.lines(spokenBy: setup.characterID) }
    private var line: ScriptLine { lines[min(index, lines.count - 1)] }
    private var characterName: String { setup.script.speaker(withID: setup.characterID)?.name ?? "You" }
    private var lineStart: Double { setup.section.start + line.start }
    private var lineEnd: Double { setup.section.start + line.end }
    private var pendingForLine: PendingTake? { pending.flatMap { $0.lineID == line.id ? $0 : nil } }
    /// The take the studio plays and describes: the unkept one just recorded, else the kept one.
    private var shownTake: RecordedTake? { pendingForLine?.take ?? takes[line.id] }
    private var shownMeasurement: TakeMeasurement? { pendingForLine?.measurement ?? measurements[line.id] }

    /// The line right before yours from someone else, so you know what you're answering.
    private var cueLine: ScriptLine? {
        setup.script.lines.last { $0.start < line.start && $0.speakerID != setup.characterID }
    }

    private var statusValue: String {
        switch activity {
        case .recording: "recording"
        case .playingOriginal: "playingOriginal"
        case .playingTake: "playingTake"
        case .idle: issue?.code == "recordingInterrupted" ? "interrupted" : "idle"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                videoCard
                progress
                if let cueLine {
                    cue(cueLine)
                }
                lineCard
                if microphone == .denied {
                    IssueCard(
                        title: "Microphone is off",
                        issue: FlowIssue(error: DubFlowError.microphoneDenied),
                        identifier: "microphonePermissionBanner",
                        value: "denied",
                        retryTitle: "Try again",
                        retryIdentifier: "retry",
                        retry: nil
                    )
                } else if let issue {
                    IssueCard(
                        title: "That didn't work",
                        issue: issue,
                        identifier: "studioError",
                        value: issue.code,
                        retryTitle: "Try again",
                        retryIdentifier: "retry",
                        retry: failedActivity.map { retryAction(for: $0) }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .containerIdentifier("studioScreen")
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .navigationTitle(characterName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back", systemImage: "chevron.backward") {
                    if takes.isEmpty && pending == nil {
                        dismiss()
                    } else {
                        isConfirmingExit = true
                    }
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("studioBack")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Finish") {
                    stopActivity()
                    onFinish(takes)
                }
                .disabled(takes.isEmpty || activity != .idle || pending != nil)
                .accessibilityIdentifier("finishDub")
            }
        }
        // Pinned so recording and keeping stay reachable however much feedback is on screen.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controls
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Palette.background)
        }
        .overlay {
            StateCarriers(items: [
                StateCarrier(identifier: "studioStatus", value: statusValue),
                StateCarrier(identifier: "studioProgress", value: "\(takes.count) of \(lines.count)"),
                StateCarrier(identifier: "currentLine", value: "\(line.id)"),
            ] + (takes[line.id] != nil ? [StateCarrier(identifier: "lineKept-\(line.id)", value: "kept")] : []))
        }
        .task {
            refreshMicrophone()
            if let curated = setup.curated {
                do {
                    let timeline = DubTimeline.curated(selection: curated, takes: [:], rules: .standard)
                    player.player.replaceCurrentItem(with: try await DubRenderer.makePreviewItem(for: timeline))
                } catch {
                    issue = FlowIssue(error: error)
                }
            }
            await player.seek(to: lineStart)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            guard
                let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                AVAudioSession.InterruptionType(rawValue: rawType) == .began
            else { return }
            interrupt(because: "a call or another app took over the audio")
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            guard
                let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
            else { return }
            interrupt(because: "your headphones were disconnected")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                interrupt(because: "Dubby left the screen")
            } else {
                // The user may have turned the microphone on in Settings, so recording re-enables on its own.
                refreshMicrophone()
            }
        }
        .confirmationDialog("Leave the studio?", isPresented: $isConfirmingExit, titleVisibility: .visible) {
            Button("Discard \(takes.count) \(takes.count == 1 ? "take" : "takes")", role: .destructive) { dismiss() }
            Button("Keep dubbing", role: .cancel) {}
        } message: {
            Text("Your kept takes aren't saved until you finish the dub.")
        }
        .onDisappear {
            stopActivity()
            do {
                try StudioAudioSession.deactivate()
            } catch {
                // The studio is gone, so there's no screen left to show this on.
                Self.logger.warning("Audio session deactivation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func retryAction(for activity: SessionActivity) -> () -> Void {
        switch activity {
        case .recording:
            return { record() }
        case .playingOriginal:
            return { listenToOriginal() }
        case .playingTake:
            return {
                if let take = shownTake {
                    playTake(take)
                }
            }
        case .idle:
            return {}
        }
    }

    private func refreshMicrophone() {
        microphone = MicrophoneAccess(AVAudioApplication.shared.recordPermission)
    }

    private var videoCard: some View {
        VStack(spacing: 0) {
            PlayerSurface(player: player.player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if activity == .idle {
                        VideoThumbnail(url: setup.clip.url, time: lineStart + line.duration / 2)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if activity == .recording {
                        Label("REC", systemImage: "circle.fill")
                            .dubFont(12, weight: .bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .frame(minHeight: 24)
                            .background(Palette.record, in: Capsule())
                            .padding(8)
                            .accessibilityIdentifier("recordingIndicator")
                    }
                }
            HStack(spacing: 8) {
                Image(systemName: activity == .idle ? "play.circle" : "waveform.circle")
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textPrimary)
                GeometryReader { proxy in
                    Capsule()
                        .fill(Palette.track)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Palette.accent)
                                .frame(width: proxy.size.width * sceneFraction)
                        }
                }
                .frame(height: 4)
                Text("\(sceneSeconds.preciseClockString) / \(setup.section.duration.preciseClockString)")
                    .dubFont(14, weight: .regular)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(8)
            .background(Palette.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var sceneSeconds: Double {
        min(max(player.currentSeconds - setup.section.start, 0), setup.section.duration)
    }

    private var sceneFraction: Double {
        setup.section.duration > 0 ? sceneSeconds / setup.section.duration : 0
    }

    private var lineFraction: Double {
        guard activity != .idle, line.duration > 0 else { return shownTake == nil ? 0 : 1 }
        return min(max((player.currentSeconds - lineStart) / line.duration, 0), 1)
    }

    private var progress: some View {
        VStack(spacing: 12) {
            AdaptiveStack(rowAlignment: .center, spacing: 4) {
                Text("Your progress")
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Text("\(takes.count) / \(lines.count) lines")
                    .foregroundStyle(Palette.accentText)
            }
            .dubFont(14, weight: .regular)
            HStack(spacing: 8) {
                ForEach(lines) { item in
                    Capsule()
                        .fill(takes[item.id] != nil ? Palette.accent : Palette.segmentInactive)
                        .overlay {
                            if item.id == line.id {
                                Capsule().strokeBorder(Palette.accentText, lineWidth: 1)
                            }
                        }
                        .frame(height: 5)
                }
            }
        }
    }

    private func cue(_ cueLine: ScriptLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(setup.script.speaker(withID: cueLine.speakerID)?.name ?? "Cue")
                .dubFont(12, weight: .semibold)
                .foregroundStyle(Palette.speakerColor(cueLine.speakerID))
            Text(cueLine.text)
                .dubFont(14, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var lineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Line \(index + 1) · \(characterName)")
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                if pendingForLine != nil {
                    Label("Keep or record again", systemImage: "questionmark.circle")
                        .dubFont(12, weight: .medium)
                        .foregroundStyle(Palette.streak)
                } else if takes[line.id] != nil {
                    Label("Kept", systemImage: "checkmark.circle.fill")
                        .dubFont(12, weight: .medium)
                        .foregroundStyle(Palette.accentText)
                }
            }
            Text(line.text)
                .dubFont(26, weight: .bold)
                .foregroundStyle(Palette.textPrimary)
                .padding(.top, 4)
            AdaptiveStack(rowAlignment: .center, spacing: 4) {
                Text("\(line.start.preciseClockString) – \(line.end.preciseClockString)")
                    .dubFont(14, weight: .regular)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Button(activity == .playingOriginal ? "Stop" : "Listen to original") {
                    if activity == .playingOriginal {
                        stopActivity()
                    } else {
                        listenToOriginal()
                    }
                }
                .dubFont(14, weight: .regular)
                .foregroundStyle(Palette.accentText)
                .frame(minHeight: 44)
                .disabled(activity == .recording || activity == .playingTake)
                .accessibilityIdentifier("listenToOriginal")
            }
            WaveformView(levels: line.envelope, playedFraction: lineFraction)
                .frame(height: 72)
            if let overrun = shownMeasurement?.overrunSeconds {
                Label(
                    String(format: "Your take runs %.1f s into the next line, so the dub cuts the last %.1f s. Try a slightly quicker read.", overrun, overrun),
                    systemImage: "scissors"
                )
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.streak)
                .accessibilityIdentifier("takeTrimNotice")
            }
            if let shownMeasurement {
                TakeFeedbackView(measurement: shownMeasurement)
            }
        }
        .padding(18)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if pendingForLine == nil {
                recordingControls
            } else {
                Text("How did that feel?")
                    .dubFont(20, weight: .bold)
                    .foregroundStyle(Palette.textPrimary)
            }
            if activity == .recording {
                Button("Cancel recording") {
                    isRecordingCancelled = true
                    stopActivity()
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("cancelRecording")
            }
            if let take = shownTake {
                Button {
                    if activity == .playingTake {
                        stopActivity()
                    } else {
                        playTake(take)
                    }
                } label: {
                    Label(activity == .playingTake ? "Stop" : "Play my take", systemImage: activity == .playingTake ? "stop.fill" : "play.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(activity == .recording || activity == .playingOriginal)
                .accessibilityIdentifier("playTake")
            }
            if pendingForLine != nil {
                AdaptiveStack(rowAlignment: .center, spacing: 12) {
                    Button("Retry") { record() }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(activity != .idle || microphone == .denied)
                        .accessibilityIdentifier("retryTake")
                    Button("Keep take", action: keepPending)
                        .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
                        .disabled(activity != .idle)
                        .accessibilityIdentifier("keepTake")
                }
            }
        }
    }

    private var recordingControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    move(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(index == 0 || pending != nil || activity != .idle)
                .accessibilityLabel("Previous line")
                .accessibilityIdentifier("studioPrevious")
                Spacer()
                recordButton
                Spacer()
                Button {
                    move(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(index >= lines.count - 1 || pending != nil || activity != .idle)
                .accessibilityLabel("Next line")
                .accessibilityIdentifier("studioNext")
            }
            .foregroundStyle(Palette.textPrimary)
            Text(recordHint)
                .dubFont(14, weight: .regular)
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
        }
    }

    private var recordButton: some View {
        Button {
            if activity == .recording {
                stopActivity()
            } else {
                record()
            }
        } label: {
            Image(systemName: activity == .recording ? "stop.fill" : "mic")
                .dubFont(30, weight: .medium)
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 78, height: 78)
                .background(Palette.record, in: Circle())
                .padding(5)
                .overlay { Circle().strokeBorder(Palette.record.opacity(0.4), lineWidth: 2) }
        }
        .disabled(activity == .playingOriginal || activity == .playingTake || microphone == .denied)
        .accessibilityLabel(activity == .recording ? "Stop recording" : "Record this line")
        .accessibilityHint(microphone == .denied ? "Unavailable: microphone access is off" : "")
        .accessibilityIdentifier("recordLine")
    }

    private var recordHint: String {
        switch activity {
        case .recording: "Recording… speak with the video"
        case .playingOriginal: "Listening to the original"
        case .playingTake: "Playing your take over the scene"
        case .idle where microphone == .denied: "Turn the microphone on in Settings to record"
        case .idle where pendingForLine != nil: "Keep this take, or record it again"
        case .idle: takes[line.id] == nil ? "Tap to record. You'll hear your cue first." : "Tap to record again. Your kept take stays until you keep a new one."
        }
    }

    private func move(by offset: Int) {
        stopActivity()
        index = min(max(index + offset, 0), lines.count - 1)
        let start = lineStart
        Task { await player.seek(to: start) }
    }

    private func keepPending() {
        guard let pending else { return }
        takes[pending.lineID] = pending.take
        measurements[pending.lineID] = pending.measurement
        self.pending = nil
    }

    private func listenToOriginal() {
        let start = lineStart
        let end = lineEnd
        run(.playingOriginal) {
            await player.seek(to: start)
            _ = await player.play(until: end, volume: 1)
        }
    }

    private func record() {
        let target = line
        let start = lineStart
        let end = lineEnd
        // A fresh file per attempt, so a stopped or failed retry never overwrites a take already kept.
        let url = setup.clip.workingDirectory.appending(path: "take-\(target.id)-\(UUID().uuidString).m4a")
        isRecordingCancelled = false
        run(.recording) {
            guard await AVAudioApplication.requestRecordPermission() else { throw DubFlowError.microphoneDenied }
            try StudioAudioSession.activate()
            await player.seek(to: max(0, start - DubTiming.cueLength))
            guard await player.play(until: start, volume: 1) else { return }
            // The video keeps rolling silently while the mic records, so the take lines up with the line start.
            try recorder.start(writingTo: url)
            _ = await player.play(until: end + DubTiming.lineGrace, volume: 0)
            let duration = recorder.stop()
            if isRecordingCancelled {
                discardFile(at: url)
                return
            }
            if let interruption {
                discardFile(at: url)
                throw DubFlowError.recordingInterrupted(interruption)
            }
            let take = RecordedTake(url: url, duration: duration)
            let measurement = await TakeMeasuring.measure(take: take, line: target, lines: setup.script.lines, sectionDuration: setup.section.duration)
            if let replaced = pending, replaced.lineID == target.id {
                discardFile(at: replaced.take.url)
            }
            pending = PendingTake(lineID: target.id, take: take, measurement: measurement)
        }
    }

    private func playTake(_ take: RecordedTake) {
        let start = lineStart
        run(.playingTake) {
            try StudioAudioSession.activate()
            await player.seek(to: start)
            try takePlayer.start(url: take.url)
            _ = await player.play(until: start + take.duration, volume: 0)
        }
    }

    /// Removes a take file that will never be used. A failure is logged because there is nothing the user can do about it.
    private func discardFile(at url: URL) {
        do {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            Self.logger.warning("Couldn't remove an unused take: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Runs one studio activity at a time and always returns the studio to idle when it ends.
    private func run(_ kind: SessionActivity, _ work: @escaping () async throws -> Void) {
        activityTask?.cancel()
        issue = nil
        failedActivity = nil
        interruption = nil
        activity = kind
        activityTask = Task {
            do {
                try await work()
            } catch {
                issue = FlowIssue(error: error)
                failedActivity = kind
            }
            refreshMicrophone()
            player.stop()
            takePlayer.stop()
            if kind == .recording {
                // A recording cut short by an error isn't kept.
                _ = recorder.stop()
            }
            activity = .idle
        }
    }

    private func stopActivity() {
        player.stop()
    }

    /// Stops whatever is playing or recording because the system took the audio away.
    private func interrupt(because reason: String) {
        guard activity != .idle else { return }
        interruption = reason
        player.stop()
        takePlayer.stop()
    }
}
