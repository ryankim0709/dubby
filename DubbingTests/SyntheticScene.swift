import AVFoundation
import Foundation
import Testing
@testable import Dubbing

/// A SYNTHETIC multi-character scene, generated at test time and never bundled in the app. It is not a demo scene
/// and is separate from the two-tone export fixture. Each character's dialogue track holds a distinct tone in that
/// character's line windows, the background holds a tone throughout, and takes hold another tone, so a spectral
/// measurement shows exactly which source is audible where.
enum SyntheticScene {
    static let sceneID = "synthetic-test-scene"
    static let duration = 10.0
    static let sampleRate = 48_000.0
    static let amplitude: Float = 0.2
    static let backgroundHz = 200.0
    static let aliceHz = 700.0
    static let bobHz = 1_300.0
    static let takeHz = 2_200.0

    struct Line {
        let id: String
        let character: String
        let start: Double
        let end: Double
    }

    /// Alice has three lines, Bob three; they alternate with gaps.
    static let lines = [
        Line(id: "synthetic-test-scene-line-01", character: "alice", start: 1.0, end: 2.0),
        Line(id: "synthetic-test-scene-line-02", character: "bob", start: 2.2, end: 3.2),
        Line(id: "synthetic-test-scene-line-03", character: "alice", start: 3.6, end: 4.6),
        Line(id: "synthetic-test-scene-line-04", character: "bob", start: 5.0, end: 6.0),
        Line(id: "synthetic-test-scene-line-05", character: "alice", start: 6.6, end: 7.6),
        Line(id: "synthetic-test-scene-line-06", character: "bob", start: 8.0, end: 9.0),
    ]

    static func fileName(_ suffix: String) -> String { "\(sceneID)-\(suffix)" }

    /// Writes the scene's media and manifest into `folder` and returns the manifest URL.
    static func make(in folder: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await writeBlackVideo(to: folder.appending(path: fileName("video.mp4")), seconds: duration, framesPerSecond: 30)
        // Not a real image: the manifest only requires the poster to exist and match its checksum.
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: folder.appending(path: fileName("poster.jpg")))
        try ToneAudio.writeAAC(
            ToneAudio.tone(backgroundHz, amplitude: amplitude, seconds: duration, sampleRate: sampleRate),
            sampleRate: sampleRate,
            to: folder.appending(path: fileName("background.m4a"))
        )
        for (character, hertz) in [("alice", aliceHz), ("bob", bobHz)] {
            let windows = lines.filter { $0.character == character }.map { TimeSpan(start: $0.start, end: $0.end) }
            try ToneAudio.writeAAC(
                ToneAudio.tone(hertz, amplitude: amplitude, seconds: duration, sampleRate: sampleRate, onlyDuring: windows),
                sampleRate: sampleRate,
                to: folder.appending(path: fileName("dialogue-\(character).m4a"))
            )
        }
        let manifestURL = folder.appending(path: fileName("manifest.json"))
        try JSONEncoder().encode(try manifest(in: folder)).write(to: manifestURL)
        return manifestURL
    }

    static func manifest(in folder: URL) throws -> SceneManifest {
        func file(_ suffix: String) throws -> SceneManifest.File {
            let name = fileName(suffix)
            return SceneManifest.File(file: name, sha256: try CuratedSceneLoader.sha256(of: folder.appending(path: name)))
        }
        return SceneManifest(
            schemaVersion: 1,
            sceneId: sceneID,
            title: "Synthetic Test Scene",
            synopsis: "Synthetic tones for engine tests.",
            locale: "en-US",
            durationSeconds: duration,
            video: try file("video.mp4"),
            poster: try file("poster.jpg"),
            background: try file("background.m4a"),
            characters: [
                SceneManifest.Character(id: "alice", displayName: "Alice", description: "Synthetic 700 Hz voice.", dialogue: try file("dialogue-alice.m4a")),
                SceneManifest.Character(id: "bob", displayName: "Bob", description: "Synthetic 1,300 Hz voice.", dialogue: try file("dialogue-bob.m4a")),
            ],
            lines: lines.map { line in
                SceneManifest.Line(id: line.id, characterId: line.character, start: line.start, end: line.end, text: "Synthetic line.", referenceVersion: 1, words: nil)
            },
            provenance: SceneManifest.Provenance(
                work: "Synthetic test scene",
                creator: "DubbingTests",
                sourceURL: "https://example.invalid/synthetic",
                license: "CC0-1.0",
                licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/",
                attribution: "Synthetic test media."
            )
        )
    }

    /// H.264 black frames with no audio track.
    static func writeBlackVideo(to url: URL, seconds: Double, framesPerSecond: Int32) async throws {
        try MediaPipeline.prepareOutput(url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting(), "the synthetic video writer should start: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let frame = try #require(pixelBuffer, "CVPixelBufferCreate failed with \(status)")
        CVPixelBufferLockBaseAddress(frame, [])
        if let base = CVPixelBufferGetBaseAddress(frame) {
            memset(base, 0, CVPixelBufferGetDataSize(frame))
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        let frameCount = Int64((seconds * Double(framesPerSecond)).rounded())
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(adaptor.append(frame, withPresentationTime: CMTime(value: index, timescale: framesPerSecond)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: frameCount, timescale: framesPerSecond))
        await writer.finishWriting()
        #expect(writer.status == .completed, "the synthetic video should finish: \(String(describing: writer.error))")
    }
}

/// Tone generation, AAC writing and spectral measurement for engine tests.
enum ToneAudio {
    static func tone(_ hertz: Double, amplitude: Float, seconds: Double, sampleRate: Double) -> [Float] {
        tone(hertz, amplitude: amplitude, seconds: seconds, sampleRate: sampleRate, onlyDuring: [TimeSpan(start: 0, end: seconds)])
    }

    /// A sine that sounds only inside `windows`, with 5 ms fades so edges don't splatter into other bands.
    static func tone(_ hertz: Double, amplitude: Float, seconds: Double, sampleRate: Double, onlyDuring windows: [TimeSpan]) -> [Float] {
        let fade = 0.005
        return (0..<Int(seconds * sampleRate)).map { index in
            let time = Double(index) / sampleRate
            guard let window = windows.first(where: { time >= $0.start && time < $0.end }) else { return 0 }
            let edge = min(1, (time - window.start) / fade, (window.end - time) / fade)
            return amplitude * Float(edge * sin(2 * .pi * hertz * time))
        }
    }

    /// Writes mono AAC in an M4A container, the format of scene tracks and takes.
    static func writeAAC(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        try MediaPipeline.prepareOutput(url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try #require(buffer.floatChannelData?[0])
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        try file.write(from: buffer)
        file.close()
    }

    /// Mono float samples of every audio track in `asset`, mixed by `audioMix` when given, at `sampleRate`.
    static func render(_ asset: AVAsset, audioMix: AVAudioMix?, sampleRate: Double) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
        ])
        output.audioMix = audioMix
        reader.add(output)
        #expect(reader.startReading(), "reading should start: \(String(describing: reader.error))")
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = try chunk.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: try #require(bytes.baseAddress))
            }
            #expect(status == kCMBlockBufferNoErr)
            samples += chunk
        }
        #expect(reader.status == .completed, "reading should complete: \(String(describing: reader.error))")
        return samples
    }

    /// Power at one frequency (Goertzel), normalized so a full-scale sine of amplitude A measures about (A/2)².
    static func power(_ samples: ArraySlice<Float>, at hertz: Double, sampleRate: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let coefficient = 2 * cos(2 * .pi * hertz / sampleRate)
        var previous = 0.0
        var beforePrevious = 0.0
        for sample in samples {
            let current = Double(sample) + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
        return power / Double(samples.count * samples.count)
    }

    static func window(_ samples: [Float], _ span: TimeSpan, sampleRate: Double) -> ArraySlice<Float> {
        let lower = min(samples.count, max(0, Int(span.start * sampleRate)))
        let upper = min(samples.count, max(lower, Int(span.end * sampleRate)))
        return samples[lower..<upper]
    }

    /// The first time, scanning in 5 ms steps with 20 ms windows from `from`, at which `hertz` reaches half the
    /// steady level measured in `steady`. Returns the window's centre.
    static func onset(of hertz: Double, in samples: [Float], from: Double, steady: TimeSpan, sampleRate: Double) -> Double? {
        let level = power(window(samples, steady, sampleRate: sampleRate), at: hertz, sampleRate: sampleRate)
        var time = from
        while time < steady.start {
            let probe = TimeSpan(start: time - 0.01, end: time + 0.01)
            if power(window(samples, probe, sampleRate: sampleRate), at: hertz, sampleRate: sampleRate) >= level / 2 {
                return time
            }
            time += 0.005
        }
        return nil
    }
}

/// A scratch folder for one test.
func scratchFolder(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
}
