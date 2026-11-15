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

/// The real dubbing studio: hear each original line, then record yours along with the muted video.
struct DubSessionView: View {
    let setup: DubSetup
    let onFinish: ([Int: RecordedTake]) -> Void
    @State private var player: SegmentPlayer
    @State private var recorder = TakeRecorder()
    @State private var takePlayer = TakePlayer()
    @State private var index = 0
    @State private var takes: [Int: RecordedTake] = [:]
    @State private var activity: SessionActivity = .idle
    @State private var activityTask: Task<Void, Never>?
    @State private var issue: FlowIssue?
    /// The activity that produced `issue`, so Try again repeats it.
    @State private var failedActivity: SessionActivity?
    @State private var measurements: [Int: TakeMeasurement] = [:]
    @State private var microphone = MicrophoneAccess(AVAudioApplication.shared.recordPermission)
    @State private var isConfirmingExit = false
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

    /// The line right before yours from someone else, so you know what you're answering.
    private var cueLine: ScriptLine? {
        setup.script.lines.last { $0.start < line.start && $0.speakerID != setup.characterID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header {
                    Button("Finish") {
                        stopActivity()
                        onFinish(takes)
                    }
                    .dubFont(14, weight: .semibold)
                    .foregroundStyle(takes.isEmpty ? Palette.textSecondary : Palette.accentText)
                    .frame(minHeight: 44)
                    .disabled(takes.isEmpty || activity != .idle)
                    .accessibilityIdentifier("finishDub")
                }
                .padding(.top, 8)
                videoCard
                progress
                if let cueLine {
                    cue(cueLine)
                }
                lineCard
                recordControls
                    .frame(maxWidth: .infinity)
                if microphone == .denied {
                    IssueCard(title: "Microphone is off", issue: FlowIssue(error: DubFlowError.microphoneDenied), retry: nil)
                } else if let issue {
                    IssueCard(title: "That didn't work", issue: issue, retry: failedActivity.map { retryAction(for: $0) })
                }
                AdaptiveStack(rowAlignment: .center, spacing: 12) {
                    Button {
                        move(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                        Text("Previous")
                    }
                    .disabled(index == 0)
                    Spacer()
                    Button {
                        move(by: 1)
                    } label: {
                        Text("Next")
                        Image(systemName: "chevron.right")
                    }
                    .disabled(index >= lines.count - 1)
                }
                .buttonStyle(OutlineCapsuleButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .background(Palette.background)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            refreshMicrophone()
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
                interrupt(because: "DubIt left the screen")
            } else {
                refreshMicrophone()
            }
        }
        .confirmationDialog("Leave the studio?", isPresented: $isConfirmingExit, titleVisibility: .visible) {
            Button("Discard \(takes.count) \(takes.count == 1 ? "take" : "takes")", role: .destructive) { dismiss() }
            Button("Keep dubbing", role: .cancel) {}
        } message: {
            Text("Your recorded takes aren't saved until you finish the dub.")
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

    private func header<Trailing: View>(@ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Button {
                if takes.isEmpty {
                    dismiss()
                } else {
                    isConfirmingExit = true
                }
            } label: {
                Image(systemName: "arrow.left")
                    .dubFont(16, weight: .medium)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back")
            Text("Dubbing studio")
                .dubFont(16, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            trailing()
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
                if let take = takes[line.id] {
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
                .overlay(alignment: .topLeading) {
                    if activity == .recording {
                        Label("REC", systemImage: "circle.fill")
                            .dubFont(12, weight: .bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .frame(minHeight: 24)
                            .background(Color.red, in: Capsule())
                            .padding(8)
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
        guard activity != .idle, line.duration > 0 else { return takes[line.id] == nil ? 0 : 1 }
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
                Text("LINE \(index + 1) · \(characterName.uppercased())")
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                if takes[line.id] != nil {
                    Label("Recorded", systemImage: "checkmark.circle.fill")
                        .dubFont(12, weight: .medium)
                        .foregroundStyle(Palette.accentText)
                }
            }
            Text(line.text)
                .dubFont(20, weight: .semibold)
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
                .disabled(activity == .recording || activity == .playingTake)
                .accessibilityIdentifier("listenToOriginal")
            }
            WaveformView(levels: line.envelope, playedFraction: lineFraction)
                .frame(height: 72)
            if let overrun = takeOverrun {
                Label(
                    String(format: "Your take runs %.1f s into the next line, so the dub cuts the last %.1f s. Try a slightly quicker read.", overrun, overrun),
                    systemImage: "scissors"
                )
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.streak)
                .accessibilityIdentifier("takeTrimNotice")
            }
            if let measurement = measurements[line.id], takes[line.id] != nil {
                TakeFeedbackView(measurement: measurement)
            }
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var recordControls: some View {
        VStack(spacing: 10) {
            Button {
                if activity == .recording {
                    stopActivity()
                } else {
                    record()
                }
            } label: {
                Image(systemName: activity == .recording ? "stop.fill" : "mic")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(activity == .recording ? .white : Palette.onAccent)
                    .frame(width: 78, height: 78)
                    .background(activity == .recording ? Color.red : Palette.accent, in: Circle())
            }
            .disabled(activity == .playingOriginal || activity == .playingTake || microphone == .denied)
            .accessibilityLabel(activity == .recording ? "Stop recording" : "Record this line")
            .accessibilityHint(microphone == .denied ? "Unavailable: microphone access is off" : "")
            .accessibilityIdentifier("recordLine")
            Text(recordHint)
                .dubFont(14, weight: .regular)
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
            if let take = takes[line.id] {
                Button {
                    if activity == .playingTake {
                        stopActivity()
                    } else {
                        playTake(take)
                    }
                } label: {
                    Image(systemName: activity == .playingTake ? "stop.fill" : "play.fill")
                    Text(activity == .playingTake ? "Stop" : "Play my take")
                }
                .buttonStyle(OutlineCapsuleButtonStyle())
                .disabled(activity == .recording || activity == .playingOriginal)
                .accessibilityIdentifier("playTake")
            }
        }
        .padding(.top, 8)
    }

    /// Seconds the current line's take will lose in the final dub, when that's enough to notice.
    private var takeOverrun: Double? {
        guard let take = takes[line.id] else { return nil }
        let allowed = ScriptBuilder.allowedTakeDuration(
            for: line,
            in: setup.script.lines,
            sectionDuration: setup.section.duration,
            grace: DubTiming.lineGrace
        )
        let overrun = take.duration - allowed
        return overrun > DubTiming.noticeableTrim ? overrun : nil
    }

    private var recordHint: String {
        switch activity {
        case .recording: "Recording… speak with the video"
        case .playingOriginal: "Listening to the original"
        case .playingTake: "Playing your take over the scene"
        case .idle where microphone == .denied: "Turn the microphone on in Settings to record"
        case .idle: takes[line.id] == nil ? "Tap to record. You'll hear your cue first." : "Tap to record again"
        }
    }

    private func move(by offset: Int) {
        stopActivity()
        index = min(max(index + offset, 0), lines.count - 1)
        let start = lineStart
        Task { await player.seek(to: start) }
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
        // A fresh file per attempt, so a stopped or failed retry never overwrites the take already accepted.
        let url = setup.clip.workingDirectory.appending(path: "take-\(target.id)-\(UUID().uuidString).m4a")
        run(.recording) {
            guard await AVAudioApplication.requestRecordPermission() else { throw DubFlowError.microphoneDenied }
            try StudioAudioSession.activate()
            await player.seek(to: max(0, start - DubTiming.cueLength))
            guard await player.play(until: start, volume: 1) else { return }
            // The video keeps rolling silently while the mic records, so the take lines up with the line start.
            try recorder.start(writingTo: url)
            _ = await player.play(until: end + DubTiming.lineGrace, volume: 0)
            let duration = recorder.stop()
            if let interruption {
                throw DubFlowError.recordingInterrupted(interruption)
            }
            let take = RecordedTake(url: url, duration: duration)
            takes[target.id] = take
            measurements[target.id] = nil
            measurements[target.id] = await TakeMeasuring.measure(take: take, line: target, lines: setup.script.lines, sectionDuration: setup.section.duration)
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
