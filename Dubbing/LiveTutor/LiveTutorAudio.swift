import AVFoundation

nonisolated enum LiveTutorAudioError: LocalizedError, Equatable {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "The tutor call couldn't use the microphone or speaker: \(reason)."
        }
    }
}

/// The call's audio: the microphone with the system's echo cancellation, so the tutor doesn't hear its own voice
/// and the learner can cut in, and a player for the tutor's voice.
final class LiveTutorAudio {
    /// Microphone samples at `microphoneSampleRate`, as captured.
    let microphone: AsyncStream<[Float]>
    private let microphoneContinuation: AsyncStream<[Float]>.Continuation
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let voiceFormat: AVAudioFormat

    init() throws {
        voiceFormat = try TutorVoice.format()
        (microphone, microphoneContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(50))
    }

    /// Opens the microphone and speaker and returns the microphone's sample rate.
    func start() throws -> Double {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: voiceFormat)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw LiveTutorAudioError.unavailable("no microphone input is available")
        }
        Self.installTap(on: input, format: inputFormat, continuation: microphoneContinuation)
        engine.prepare()
        try engine.start()
        player.play()
        return inputFormat.sampleRate
    }

    /// Queues the tutor's voice behind whatever is already playing.
    func play(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        player.scheduleBuffer(try TutorVoice.buffer(samples, format: voiceFormat))
        if !player.isPlaying { player.play() }
    }

    /// Drops the tutor's queued voice at once, for when the learner cuts in.
    func stopPlayback() {
        player.stop()
        player.play()
    }

    /// Closes the microphone and speaker and lets other apps' audio resume.
    func stop() throws {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        microphoneContinuation.finish()
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Built outside the main actor so the tap, which runs on the audio thread, isn't isolated to it.
    nonisolated private static func installTap(on node: AVAudioInputNode, format: AVAudioFormat, continuation: AsyncStream<[Float]>.Continuation) {
        // About 50 ms a buffer: small enough for quick turn detection, large enough not to flood the socket.
        let bufferSize = AVAudioFrameCount(format.sampleRate / 20)
        node.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            continuation.yield(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
        }
    }
}

/// The tutor's voice as the player takes it: 24 kHz mono float samples.
nonisolated enum TutorVoice {
    static func format() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: LiveTutorRealtime.sampleRate, channels: 1, interleaved: false) else {
            throw LiveTutorAudioError.unavailable("the tutor's voice format isn't supported")
        }
        return format
    }

    static func buffer(_ samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)), let channel = buffer.floatChannelData?[0] else {
            throw LiveTutorAudioError.unavailable("the tutor's voice couldn't be buffered")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        return buffer
    }
}

/// Plays the take coach's voice through whatever audio session the studio has set up. It never opens the
/// microphone, so it can't get in the way of recording.
final class TutorVoicePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    init() throws {
        format = try TutorVoice.format()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        // The studio switches the audio session for recording and playback, which stops a running engine.
        if !engine.isRunning { try engine.start() }
        player.scheduleBuffer(try TutorVoice.buffer(samples, format: format))
        if !player.isPlaying { player.play() }
    }

    func stop() {
        player.stop()
    }

    func shutDown() {
        player.stop()
        engine.stop()
    }
}

/// Converts mono float samples to the 24 kHz PCM 16-bit the Realtime API takes. One encoder serves one stream,
/// because the converter carries resampling state from one buffer to the next.
nonisolated final class LiveTutorMicrophoneEncoder {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat

    init(inputSampleRate: Double) throws {
        guard
            let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate, channels: 1, interleaved: false),
            let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: LiveTutorRealtime.sampleRate, channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw LiveTutorAudioError.unavailable("the microphone's \(Int(inputSampleRate)) Hz audio can't be converted")
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    func encode(_ samples: [Float]) throws -> Data {
        guard !samples.isEmpty else { return Data() }
        let frames = AVAudioFrameCount(samples.count)
        let capacity = AVAudioFrameCount((Double(samples.count) * outputFormat.sampleRate / inputFormat.sampleRate).rounded(.up)) + 64
        guard
            let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames),
            let inputChannel = input.floatChannelData?[0],
            let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        else {
            throw LiveTutorAudioError.unavailable("the microphone audio couldn't be buffered")
        }
        input.frameLength = frames
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            inputChannel.update(from: base, count: samples.count)
        }
        var isSupplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            // Each call converts exactly this buffer; the converter keeps any remainder for the next one.
            guard !isSupplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            isSupplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw LiveTutorAudioError.unavailable("converting the microphone audio failed: \(conversionError?.localizedDescription ?? "no reason given")")
        }
        guard let outputChannel = output.int16ChannelData?[0] else {
            throw LiveTutorAudioError.unavailable("the converted microphone audio was empty")
        }
        return Data(bytes: outputChannel, count: Int(output.frameLength) * LiveTutorRealtime.bytesPerFrame)
    }
}
