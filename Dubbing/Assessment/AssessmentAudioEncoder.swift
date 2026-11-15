import AVFoundation
import Foundation

/// A 16 kHz mono 16-bit PCM WAV ready to upload. The original take is never modified.
nonisolated struct EncodedRecording: Equatable, Sendable {
    let url: URL
    let durationMs: Int
    let byteCount: Int
}

nonisolated enum AssessmentAudioError: LocalizedError, Equatable {
    case unreadableSource(String)
    case noAudio
    case tooLong(durationMs: Int, limitMs: Int)
    case destinationIsSource
    case conversionFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableSource(let reason): "The recording couldn't be read: \(reason)"
        case .noAudio: "The recording has no audio."
        case .tooLong(let durationMs, let limitMs): "The recording lasts \(durationMs) ms, over the \(limitMs) ms limit for pronunciation assessment."
        case .destinationIsSource: "The assessment copy must be written to a different file than the original take."
        case .conversionFailed(let reason): "The recording couldn't be converted for assessment: \(reason)"
        case .writeFailed(let reason): "The assessment copy couldn't be saved: \(reason)"
        }
    }
}

/// Converts an original take to the upload format the assessment service accepts. Overlong takes are rejected, not truncated.
nonisolated enum AssessmentAudioEncoder {
    static let sampleRate = 16_000
    /// Azure documents 30 seconds as the longest audio for pronunciation assessment over REST.
    static let maxDurationMs = 30_000

    private static let headerByteCount = 44
    private static let chunkFrames: AVAudioFrameCount = 4_096

    static func encode(from source: URL, to destination: URL) throws -> EncodedRecording {
        guard source.standardizedFileURL != destination.standardizedFileURL else { throw AssessmentAudioError.destinationIsSource }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: source)
        } catch {
            throw AssessmentAudioError.unreadableSource(error.localizedDescription)
        }
        guard file.length > 0 else { throw AssessmentAudioError.noAudio }
        let sourceMs = Int((Double(file.length) / file.processingFormat.sampleRate * 1000).rounded())
        guard sourceMs <= maxDurationMs else { throw AssessmentAudioError.tooLong(durationMs: sourceMs, limitMs: maxDurationMs) }

        guard
            let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: file.processingFormat, to: target),
            let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames * 2),
            let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: chunkFrames)
        else {
            throw AssessmentAudioError.conversionFailed("the audio format isn't supported")
        }

        var samples = Data()
        var readFailure: String?
        var finished = false
        while !finished {
            var convertError: NSError?
            let status = converter.convert(to: output, error: &convertError) { _, inputStatus in
                // Reading at the end of the file throws instead of returning zero frames, so stop before asking.
                let remaining = file.length - file.framePosition
                if remaining <= 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: AVAudioFrameCount(min(Int64(input.frameCapacity), remaining)))
                } catch {
                    readFailure = error.localizedDescription
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if input.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if let readFailure { throw AssessmentAudioError.unreadableSource(readFailure) }
            switch status {
            case .error:
                throw AssessmentAudioError.conversionFailed(convertError?.localizedDescription ?? "unknown converter error")
            case .endOfStream:
                finished = true
            case .haveData, .inputRanDry:
                break
            @unknown default:
                throw AssessmentAudioError.conversionFailed("unexpected converter status")
            }
            if output.frameLength > 0, let channel = output.int16ChannelData?[0] {
                samples.append(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
        }

        let frameCount = samples.count / MemoryLayout<Int16>.size
        guard frameCount > 0 else { throw AssessmentAudioError.noAudio }
        let durationMs = Int((Double(frameCount) / Double(sampleRate) * 1000).rounded())
        guard durationMs <= maxDurationMs else { throw AssessmentAudioError.tooLong(durationMs: durationMs, limitMs: maxDurationMs) }

        let wav = header(dataByteCount: samples.count) + samples
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try wav.write(to: destination, options: .atomic)
        } catch {
            throw AssessmentAudioError.writeFailed(error.localizedDescription)
        }
        return EncodedRecording(url: destination, durationMs: durationMs, byteCount: wav.count)
    }

    /// The canonical 44-byte RIFF/WAVE header for mono 16-bit PCM at 16 kHz.
    private static func header(dataByteCount: Int) -> Data {
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF")
        append(UInt32(36 + dataByteCount))
        append("WAVE")
        append("fmt ")
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        append("data")
        append(UInt32(dataByteCount))
        return data
    }
}
