import Foundation

nonisolated enum SocialAudioProtection {
    /// Suppression padding may reach the next speaker; never filter a teammate's already-recorded voice.
    static func subtract(_ protected: [TimeSpan], from spans: [TimeSpan]) -> [TimeSpan] {
        spans.flatMap { span in
            protected.sorted { $0.start < $1.start }.reduce([span]) { remaining, keep in
                remaining.flatMap { current -> [TimeSpan] in
                    if keep.end <= current.start || keep.start >= current.end { return [current] }
                    let before: [TimeSpan] = current.start < keep.start ? [TimeSpan(start: current.start, end: keep.start)] : []
                    let after: [TimeSpan] = keep.end < current.end ? [TimeSpan(start: keep.end, end: current.end)] : []
                    return before + after
                }
            }
        }
    }
}
