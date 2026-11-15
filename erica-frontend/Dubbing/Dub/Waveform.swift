import AVFoundation

/// Amplitude over time, one RMS value per bin, starting at the beginning of its source file.
nonisolated struct Envelope: Hashable, Sendable {
    let values: [Float]
    let binDuration: Double

    var duration: Double { Double(values.count) * binDuration }

    /// Amplitude at a time offset from the start of the source, or nil outside it.
    func value(at offset: Double) -> Float? {
        guard offset >= 0, binDuration > 0 else { return nil }
        let index = Int(offset / binDuration)
        return values.indices.contains(index) ? values[index] : nil
    }
}

nonisolated enum WaveformError: Error {
    case unsupportedFormat
}

nonisolated enum Waveform {
    static func rmsBins(samples: [Float], binSize: Int) -> [Float] {
        guard binSize > 0, !samples.isEmpty else { return [] }
        return stride(from: 0, to: samples.count, by: binSize).map { start in
            let end = min(start + binSize, samples.count)
            var sum: Float = 0
            for index in start..<end {
                sum += samples[index] * samples[index]
            }
            return (sum / Float(end - start)).squareRoot()
        }
    }

    /// Decodes an audio file off the main actor and reduces it to an envelope.
    @concurrent
    static func envelope(of url: URL, binsPerSecond: Double) async throws -> Envelope {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let binSize = max(1, Int(format.sampleRate / binsPerSecond))
        let binDuration = Double(binSize) / format.sampleRate
        guard file.length > 0 else {
            return Envelope(values: [], binDuration: binDuration)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw WaveformError.unsupportedFormat
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw WaveformError.unsupportedFormat
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return Envelope(values: rmsBins(samples: samples, binSize: binSize), binDuration: binDuration)
    }
}
