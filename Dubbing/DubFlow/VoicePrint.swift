import Accelerate
import Foundation

/// Timbre fingerprints for telling speakers apart, and clustering lines by them.
nonisolated enum VoicePrint {
    private static let frameLength = 1_024
    private static let filterCount = 26
    /// MFCCs 1–12; coefficient 0 is overall loudness, which says more about delivery than about who is speaking.
    private static let coefficients = 1...12

    /// Median periodicity of voiced frames, used only to choose a broad voice register.
    static func pitchHz(samples: [Float], sampleRate: Double) -> Double? {
        let step = max(1, Int(sampleRate / 4_000))
        let rate = sampleRate / Double(step)
        let reduced = stride(from: 0, to: samples.count, by: step).map { Double(samples[$0]) }
        let frameLength = Int(rate * 0.04)
        guard reduced.count >= frameLength else { return nil }
        let lags = Int(rate / 400)...Int(rate / 70)
        var pitches: [Double] = []
        for start in stride(from: 0, through: reduced.count - frameLength, by: frameLength) {
            let frame = Array(reduced[start..<(start + frameLength)])
            let mean = frame.reduce(0, +) / Double(frame.count)
            let centered = frame.map { $0 - mean }
            guard centered.reduce(0, { $0 + $1 * $1 }) / Double(frameLength) > 1e-6 else { continue }
            let correlations = lags.map { lag -> Double in
                var product = 0.0
                var leftEnergy = 0.0
                var rightEnergy = 0.0
                for index in 0..<(frameLength - lag) {
                    let left = centered[index]
                    let right = centered[index + lag]
                    product += left * right
                    leftEnergy += left * left
                    rightEnergy += right * right
                }
                return product / max((leftEnergy * rightEnergy).squareRoot(), 1e-12)
            }
            guard let peak = correlations.max(), peak >= 0.8 else { continue }
            // Prefer the first strong peak so a repeated period doesn't halve the pitch.
            let candidates = 1..<(correlations.count - 1)
            if let index = candidates.first(where: {
                correlations[$0] >= peak * 0.95 && correlations[$0] > correlations[$0 - 1] && correlations[$0] >= correlations[$0 + 1]
            }) {
                pitches.append(rate / Double(lags.lowerBound + index))
            }
        }
        let ordered = pitches.sorted()
        return ordered.isEmpty ? nil : ordered[ordered.count / 2]
    }

    /// Mean MFCCs over a line's louder frames, or nil when the line has no clear audio.
    static func features(samples: [Float], sampleRate: Double) throws -> [Double]? {
        guard samples.count >= frameLength else { return nil }
        let dft = try vDSP.DiscreteFourierTransform(
            previous: nil,
            count: frameLength,
            direction: .forward,
            transformType: .complexComplex,
            ofType: Float.self
        )
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameLength, isHalfWindow: false)
        let filters = melFilterbank(binCount: frameLength / 2, sampleRate: sampleRate, lowHz: 100, highHz: min(4_000, sampleRate / 2))
        let silence = [Float](repeating: 0, count: frameLength)

        let starts = Array(stride(from: 0, through: samples.count - frameLength, by: frameLength / 2))
        let energies = starts.map { vDSP.rootMeanSquare(samples[$0..<($0 + frameLength)]) }
        let loudness = energies.sorted()[min(energies.count - 1, Int(Double(energies.count) * 0.9))]
        guard loudness > 1e-4 else { return nil }

        var sums = [Double](repeating: 0, count: coefficients.count)
        var frameCount = 0
        for (start, energy) in zip(starts, energies) where energy >= loudness * 0.3 {
            let frame = vDSP.multiply(samples[start..<(start + frameLength)], window)
            let spectrum = dft.transform(real: frame, imaginary: silence)
            let bins = 0..<(frameLength / 2)
            let power = vDSP.add(vDSP.square(spectrum.real[bins]), vDSP.square(spectrum.imaginary[bins]))
            let logMel = filters.map { log(Double(max(vDSP.dot(power, $0), 1e-10))) }
            for (slot, coefficient) in coefficients.enumerated() {
                sums[slot] += dctTerm(logMel, coefficient: coefficient)
            }
            frameCount += 1
        }
        guard frameCount > 0 else { return nil }
        return sums.map { $0 / Double(frameCount) }
    }

    /// Groups lines into `speakerCount` voices with k-means on standardized fingerprints.
    /// Lines without a fingerprint take the previous line's voice. Voices are numbered in order of first appearance.
    static func clusterSpeakers(prints: [[Double]?], speakerCount: Int) -> [Int] {
        let present = prints.compactMap { $0 }
        let clusterCount = min(max(speakerCount, 1), present.count)
        guard clusterCount > 1, let dimensions = present.first?.count else {
            return Array(repeating: 0, count: prints.count)
        }

        // Standardizing keeps one large coefficient from dominating the distance.
        let means = (0..<dimensions).map { dimension in present.reduce(0) { $0 + $1[dimension] } / Double(present.count) }
        let deviations = (0..<dimensions).map { dimension in
            let variance = present.reduce(0) { $0 + pow($1[dimension] - means[dimension], 2) } / Double(present.count)
            return variance > 0 ? variance.squareRoot() : 1
        }
        func standardized(_ print: [Double]) -> [Double] {
            (0..<dimensions).map { (print[$0] - means[$0]) / deviations[$0] }
        }
        let points = present.map(standardized)

        // Farthest-point seeding is deterministic and spreads the starting centroids across distinct voices.
        var centroids = [points[0]]
        while centroids.count < clusterCount {
            let next = points.max { lhs, rhs in
                centroids.map { distance(lhs, $0) }.min() ?? 0 < centroids.map { distance(rhs, $0) }.min() ?? 0
            } ?? points[0]
            centroids.append(next)
        }
        func nearest(_ point: [Double]) -> Int {
            var best = 0
            for index in centroids.indices where distance(point, centroids[index]) < distance(point, centroids[best]) {
                best = index
            }
            return best
        }
        for _ in 0..<25 {
            var sums = Array(repeating: [Double](repeating: 0, count: dimensions), count: clusterCount)
            var counts = Array(repeating: 0, count: clusterCount)
            for point in points {
                let cluster = nearest(point)
                sums[cluster] = zip(sums[cluster], point).map(+)
                counts[cluster] += 1
            }
            let updated = centroids.indices.map { index in
                counts[index] > 0 ? sums[index].map { $0 / Double(counts[index]) } : centroids[index]
            }
            if updated == centroids { break }
            centroids = updated
        }

        var clusters: [Int?] = []
        for print in prints {
            clusters.append(print.map { nearest(standardized($0)) } ?? clusters.last ?? nil)
        }
        let firstKnown = clusters.compactMap { $0 }.first ?? 0
        var labels: [Int: Int] = [:]
        return clusters.map { cluster in
            let resolved = cluster ?? firstKnown
            if let label = labels[resolved] { return label }
            let label = labels.count
            labels[resolved] = label
            return label
        }
    }

    private static func distance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        zip(lhs, rhs).reduce(0) { $0 + pow($1.0 - $1.1, 2) }
    }

    private static func dctTerm(_ values: [Double], coefficient: Int) -> Double {
        let count = Double(values.count)
        return values.enumerated().reduce(0) { sum, entry in
            sum + entry.element * cos(Double.pi * Double(coefficient) * (Double(entry.offset) + 0.5) / count)
        }
    }

    /// Triangular filters evenly spaced on the mel scale, one weight per FFT bin.
    private static func melFilterbank(binCount: Int, sampleRate: Double, lowHz: Double, highHz: Double) -> [[Float]] {
        func mel(_ hz: Double) -> Double { 2_595 * log10(1 + hz / 700) }
        func hz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2_595) - 1) }
        let edges = (0...(filterCount + 1)).map { index in
            hz(mel(lowHz) + (mel(highHz) - mel(lowHz)) * Double(index) / Double(filterCount + 1))
        }
        let binHz = sampleRate / Double(binCount * 2)
        return (1...filterCount).map { filter in
            (0..<binCount).map { bin in
                let frequency = Double(bin) * binHz
                let (lower, center, upper) = (edges[filter - 1], edges[filter], edges[filter + 1])
                if frequency <= lower || frequency >= upper { return 0 }
                return Float(frequency < center ? (frequency - lower) / (center - lower) : (upper - frequency) / (upper - center))
            }
        }
    }
}
