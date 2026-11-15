import Accelerate
import Foundation

nonisolated enum SpeechBandFilterError: LocalizedError {
    case unsupportedSampleRate(Double)

    var errorDescription: String? {
        switch self {
        case .unsupportedSampleRate(let rate):
            "The speech-band filter can't run at \(Int(rate)) Hz."
        }
    }
}

/// Cuts the band where speech lives while leaving bass and treble alone.
nonisolated enum SpeechBandFilter {
    static let centerHz = 1_200.0
    /// Width in octaves: 1,200 Hz ± 1.5 octaves spans roughly 420–3,400 Hz.
    static let bandwidthOctaves = 3.0
    /// Cascaded identical sections deepen the cut across the band.
    static let sectionCount = 3

    static func apply(to samples: [Float], sampleRate: Double) throws -> [Float] {
        guard sampleRate > centerHz * 4 else { throw SpeechBandFilterError.unsupportedSampleRate(sampleRate) }
        let section = bandStopCoefficients(sampleRate: sampleRate)
        guard var biquad = vDSP.Biquad(
            coefficients: Array((0..<sectionCount).map { _ in section }.joined()),
            channelCount: 1,
            sectionCount: vDSP_Length(sectionCount),
            ofType: Float.self
        ) else {
            throw SpeechBandFilterError.unsupportedSampleRate(sampleRate)
        }
        return biquad.apply(input: samples)
    }

    /// RBJ audio-EQ-cookbook band-stop, normalized and ordered as vDSP expects: b0, b1, b2, a1, a2.
    private static func bandStopCoefficients(sampleRate: Double) -> [Double] {
        let omega = 2 * Double.pi * centerHz / sampleRate
        let alpha = sin(omega) * sinh(log(2) / 2 * bandwidthOctaves * omega / sin(omega))
        let a0 = 1 + alpha
        return [1 / a0, -2 * cos(omega) / a0, 1 / a0, -2 * cos(omega) / a0, (1 - alpha) / a0]
    }
}
