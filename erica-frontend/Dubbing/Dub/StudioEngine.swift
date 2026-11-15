import AVFoundation
import Observation

enum StudioPhase: Equatable {
    case loading
    case ready
    case listening
    case recording
    /// Playing the fresh take over the moving scene, right after recording.
    case replaying
    /// A take is waiting for Retry or Keep; the coach is on screen.
    case reviewing
    case watchingScene
    case failed(StudioError)
}

enum StudioError: Error, Equatable, Identifiable {
    case invalidScene
    case media(String)
    case microphoneDenied
    case audioSession(String)
    case recording(String)

    var id: String { message }

    var message: String {
        switch self {
        case .invalidScene:
            "This scene's script doesn't line up with its media, so it can't be dubbed yet."
        case .media(let detail):
            "The scene couldn't load: \(detail)"
        case .microphoneDenied:
            "Dubby needs the microphone to record your lines. Turn it on in Settings › Dubby."
        case .audioSession(let detail):
            "Audio couldn't start: \(detail)"
        case .recording(let detail):
            "That take didn't record: \(detail)"
        }
    }
}

struct LineResult: Hashable {
    let take: Take
    let envelope: Envelope
    let timing: TimingAssessment
}

/// A microphone level reading at a scene time, for the live waveform while recording.
struct LevelSample: Hashable {
    let time: Double
    let level: Float
}

/// Runs the line-by-line dubbing loop for one character: listen to the original in picture,
/// record over the scene with that character's voice removed, replay the take in picture,
/// then keep it or go again. Pronunciation assessment from the backend plugs in where
/// `finishRecording` assesses timing.
@Observable
final class StudioEngine {
    static let preRoll = 2.0
    static let tail = 0.8
    static let binsPerSecond = 60.0

    let scene: SceneClip
    let character: SceneCharacter
    let myLines: [ScriptLine]
    /// The app is silent by design: the scene plays as picture only, so nothing sounds while the
    /// user records, and takes are judged by waveform and timing.
    let player: AVPlayer = {
        let player = AVPlayer()
        player.isMuted = true
        return player
    }()

    private(set) var phase: StudioPhase = .loading
    private(set) var currentIndex = 0
    private(set) var playhead: Double = 0
    private(set) var accepted: [String: LineResult] = [:]
    private(set) var pending: LineResult?
    private(set) var originalEnvelope: Envelope?
    private(set) var liveLevels: [LevelSample] = []
    var alert: StudioError?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var recordingStart: Double = 0
    @ObservationIgnored private var transportTask: Task<Void, Never>?
    @ObservationIgnored private let takesDirectory: URL

    init(scene: SceneClip, character: SceneCharacter) {
        let lines = scene.lines(for: character.id)
        precondition(!lines.isEmpty, "Casting only offers characters with lines")
        self.scene = scene
        self.character = character
        self.myLines = lines
        self.takesDirectory = URL.applicationSupportDirectory
            .appending(path: "Takes", directoryHint: .isDirectory)
            .appending(path: "\(scene.id)-\(character.id)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    var currentLine: ScriptLine { myLines[currentIndex] }
    var isComplete: Bool { myLines.allSatisfy { accepted[$0.id] != nil } }
    var hasAnyAccepted: Bool { !accepted.isEmpty }
    var currentResult: LineResult? { pending ?? accepted[currentLine.id] }
    var isBusy: Bool { [.listening, .recording, .replaying, .watchingScene].contains(phase) }

    /// The stretch of the scene shown and played around a line: a lead-in to catch the cue and a short tail.
    func window(for line: ScriptLine) -> ClosedRange<Double> {
        max(0, line.start - Self.preRoll)...min(scene.duration, line.end + Self.tail)
    }

    func summary(partner: Friend?) -> DubSummary {
        DubSummary(
            scene: scene,
            characterID: character.id,
            partner: partner,
            takes: myLines.compactMap { accepted[$0.id]?.take },
            timingScores: accepted.compactMapValues { $0.timing.score }
        )
    }

    // MARK: Lifecycle

    func prepare() async {
        guard phase == .loading else { return }
        guard scene.validationIssues.isEmpty, let stem = scene.media.stems[character.id] else {
            phase = .failed(.invalidScene)
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            phase = .failed(.audioSession(error.localizedDescription))
            return
        }
        do {
            try FileManager.default.createDirectory(at: takesDirectory, withIntermediateDirectories: true)
            originalEnvelope = try await Waveform.envelope(of: try MediaLibrary.url(for: stem), binsPerSecond: Self.binsPerSecond)
            try await load(voicing: Set(scene.characters.map(\.id)), takes: [])
            await seek(to: window(for: currentLine).lowerBound)
            phase = .ready
        } catch {
            phase = .failed(.media(error.localizedDescription))
        }
    }

    /// Takes live only as long as the dub flow: the wrap screen renders from them while the studio
    /// stays on the navigation stack, and the rendered MP4 is a separate file.
    deinit {
        do {
            try FileManager.default.removeItem(at: takesDirectory)
        } catch {
            // Nothing was recorded, or the system already purged it; either way nothing is left to clean.
            return
        }
    }

    // MARK: Actions

    func listen() async {
        await play(
            voicing: Set(scene.characters.map(\.id)),
            takes: [],
            range: max(0, currentLine.start - 0.5)...min(scene.duration, currentLine.end + 0.4),
            phase: .listening
        )
    }

    func playMine() async {
        guard let result = currentResult else { return }
        var takes = acceptedTakes(excluding: currentLine.id)
        takes.append(result.take)
        await play(voicing: otherVoices, takes: takes, range: window(for: currentLine), phase: .replaying)
    }

    func watchScene() async {
        await play(voicing: otherVoices, takes: myLines.compactMap { accepted[$0.id]?.take }, range: 0...scene.duration, phase: .watchingScene)
    }

    func record() async {
        stop()
        guard await hasMicrophoneAccess() else {
            alert = .microphoneDenied
            return
        }
        let line = currentLine
        let window = window(for: line)
        let fileURL = takesDirectory.appending(path: "\(line.id)-\(UUID().uuidString).m4a")
        do {
            let recorder = try AVAudioRecorder(url: fileURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord() else {
                throw StudioError.recording("the microphone couldn't start.")
            }
            try await load(voicing: otherVoices, takes: acceptedTakes(excluding: line.id))
            await seek(to: window.lowerBound)
            liveLevels = []
            recordingStart = window.lowerBound
            self.recorder = recorder
            // Start capture and playback in the same turn so the take lines up with the picture.
            player.play()
            guard recorder.record() else {
                self.recorder = nil
                player.pause()
                throw StudioError.recording("the microphone is in use by another app.")
            }
            phase = .recording
            runTransport(until: window.upperBound)
        } catch let error as StudioError {
            alert = error
            phase = restingPhase
        } catch {
            alert = .recording(error.localizedDescription)
            phase = restingPhase
        }
    }

    /// Discards the pending take and records again. An already-kept take stays until a new one is kept.
    func retry() async {
        discardPending()
        await record()
    }

    func keep() {
        guard let pending else { return }
        if let previous = accepted[currentLine.id] {
            removeFile(previous.take.fileURL)
        }
        accepted[currentLine.id] = pending
        self.pending = nil
        if let next = myLines.indices.first(where: { accepted[myLines[$0].id] == nil }) {
            currentIndex = next
        }
        phase = .ready
        Task { await seek(to: window(for: currentLine).lowerBound) }
    }

    func select(lineAt index: Int) {
        guard myLines.indices.contains(index), index != currentIndex else { return }
        stop()
        discardPending()
        currentIndex = index
        phase = .ready
        Task { await seek(to: window(for: currentLine).lowerBound) }
    }

    /// Stops playback, and cancels a recording in progress without keeping it.
    func stop() {
        transportTask?.cancel()
        transportTask = nil
        if let recorder {
            recorder.stop()
            removeFile(recorder.url)
            self.recorder = nil
        }
        player.pause()
        if isBusy {
            phase = restingPhase
        }
    }

    // MARK: Transport

    private enum TransportEnd {
        case recording
        case playback(isReplayAfterRecording: Bool)
    }

    private var restingPhase: StudioPhase { pending == nil ? .ready : .reviewing }
    private var otherVoices: Set<String> { Set(scene.characters.map(\.id)).subtracting([character.id]) }

    private func acceptedTakes(excluding lineID: String) -> [Take] {
        myLines.filter { $0.id != lineID }.compactMap { accepted[$0.id]?.take }
    }

    private func play(voicing: Set<String>, takes: [Take], range: ClosedRange<Double>, phase newPhase: StudioPhase) async {
        stop()
        do {
            try await load(voicing: voicing, takes: takes)
        } catch {
            alert = .media(error.localizedDescription)
            return
        }
        await seek(to: range.lowerBound)
        player.play()
        phase = newPhase
        runTransport(until: range.upperBound)
    }

    private func runTransport(until stopTime: Double) {
        transportTask?.cancel()
        transportTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let time = self.player.currentTime().seconds
                if time.isFinite {
                    self.playhead = time
                }
                if let recorder = self.recorder, recorder.isRecording {
                    recorder.updateMeters()
                    let level = Float(pow(10, Double(recorder.averagePower(forChannel: 0)) / 20))
                    self.liveLevels.append(LevelSample(time: self.playhead, level: level))
                }
                let itemEnd = self.player.currentItem?.duration.seconds ?? .infinity
                if self.playhead >= stopTime || (itemEnd.isFinite && self.playhead >= itemEnd - 0.05) {
                    await self.finishTransport()
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(33))
                } catch {
                    return
                }
            }
        }
    }

    private func finishTransport() async {
        transportTask = nil
        player.pause()
        switch phase {
        case .recording:
            await finishRecording()
        case .replaying where pending != nil:
            phase = .reviewing
        default:
            phase = restingPhase
        }
    }

    private func finishRecording() async {
        guard let recorder else { return }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        let line = currentLine
        let take = Take(id: UUID(), lineID: line.id, fileURL: recorder.url, sceneStart: recordingStart, duration: duration)
        do {
            let envelope = try await Waveform.envelope(of: take.fileURL, binsPerSecond: Self.binsPerSecond)
            let timing = TimingAnalyzer.assess(take: envelope, takeSceneStart: take.sceneStart, lineStart: line.start, lineEnd: line.end)
            discardPending()
            pending = LineResult(take: take, envelope: envelope, timing: timing)
        } catch {
            removeFile(take.fileURL)
            alert = .recording(error.localizedDescription)
            phase = restingPhase
            return
        }
        // Instant replay: the user hears their take in picture before deciding.
        await playMine()
    }

    private func load(voicing: Set<String>, takes: [Take]) async throws {
        let composition = try await SceneComposer.composition(for: scene, voicing: voicing, takes: takes)
        let item = AVPlayerItem(asset: composition)
        player.replaceCurrentItem(with: item)
        // Wait until the item can play so capture doesn't start ahead of the picture.
        for _ in 0..<150 {
            switch item.status {
            case .readyToPlay:
                return
            case .failed:
                throw item.error ?? MediaError.playerNotReady
            default:
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        throw MediaError.playerNotReady
    }

    private func seek(to seconds: Double) async {
        _ = await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = seconds
    }

    private func hasMicrophoneAccess() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func discardPending() {
        if let pending {
            removeFile(pending.take.fileURL)
        }
        pending = nil
    }

    private func removeFile(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // Takes live in a per-session temp folder; anything left behind is removed with it.
            return
        }
    }
}
