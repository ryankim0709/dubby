import AVFoundation
import SwiftUI
import UIKit

/// Whether the user let the app use the microphone.
nonisolated enum MicrophoneAccess: Equatable, Sendable {
    case undetermined
    case granted
    case denied

    init(_ permission: AVAudioApplication.recordPermission) {
        switch permission {
        case .granted: self = .granted
        case .denied: self = .denied
        default: self = .undetermined
        }
    }
}

/// A failure the user can act on: its message, and whether the fix lives in Settings.
nonisolated struct FlowIssue: Equatable, Sendable {
    let message: String
    let opensSettings: Bool

    init(error: any Error) {
        message = error.localizedDescription
        let denial = error as? DubFlowError
        opensSettings = denial == .microphoneDenied || denial == .speechRecognitionDenied
    }
}

struct OpenSettingsButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        }
        .buttonStyle(OutlineCapsuleButtonStyle())
        .accessibilityIdentifier("openSettings")
    }
}

/// A failure with its recovery: retry the step, and Settings when a permission is off.
struct IssueCard: View {
    let title: String
    let issue: FlowIssue
    let retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "exclamationmark.triangle")
                .dubFont(16, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
            Text(issue.message)
                .dubFont(14, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
            AdaptiveStack(rowAlignment: .center, spacing: 8) {
                if issue.opensSettings {
                    OpenSettingsButton()
                }
                if let retry {
                    Button("Try again", action: retry)
                        .buttonStyle(OutlineCapsuleButtonStyle())
                        .accessibilityIdentifier("retry")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}

/// A single labelled measurement. A nil value reads "Not measured" rather than a placeholder number.
struct MeasurementRow: View {
    let label: String
    let value: String?

    var body: some View {
        AdaptiveStack(rowAlignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .dubFont(14, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            Text(value ?? "Not measured")
                .dubFont(14, weight: .medium)
                .foregroundStyle(value == nil ? Palette.placeholder : Palette.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

extension TakeMeasurement {
    var lengthDescription: String {
        let length = String(format: "%.1f s take, %.1f s line", takeSeconds, lineSeconds)
        guard let overrunSeconds else { return length }
        return length + String(format: "; the last %.1f s is cut", overrunSeconds)
    }

    var levelDescription: String? {
        switch level {
        case .silent: "No voice picked up"
        case .quiet: "Quiet"
        case .clear: "Clear"
        case nil: nil
        }
    }
}

/// What was measured about one take, and an honest note about what was not.
struct TakeFeedbackView: View {
    let measurement: TakeMeasurement

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MeasurementRow(label: "Length", value: measurement.lengthDescription)
            MeasurementRow(label: "Mic level", value: measurement.levelDescription)
            MeasurementRow(label: "Pronunciation", value: nil)
            if measurement.level == .silent {
                Label("The microphone heard no voice. Check it isn't covered, then record again.", systemImage: "mic.slash")
                    .dubFont(12, weight: .regular)
                    .foregroundStyle(Palette.streak)
            } else if measurement.level == .quiet {
                Label("This take is quiet. Move a little closer to the microphone and try again.", systemImage: "speaker.wave.1")
                    .dubFont(12, weight: .regular)
                    .foregroundStyle(Palette.streak)
            }
        }
        .padding(12)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("takeFeedback")
    }
}

/// The measurements saved with a dub. A dub saved without them says so.
struct TakeSummaryView: View {
    let measurements: [TakeMeasurement]?

    var body: some View {
        let practice = MeasuredPractice(measurements: measurements ?? [])
        VStack(alignment: .leading, spacing: 8) {
            Text("Measured on this device")
                .dubFont(16, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
            if practice.hasMeasurements {
                MeasurementRow(label: "Takes that fit their line", value: "\(practice.takesFittingLine) of \(practice.measuredTakes)")
                MeasurementRow(label: "Takes with a clear voice", value: "\(practice.takesWithVoice) of \(practice.measuredTakes)")
            } else {
                MeasurementRow(label: "Take length and mic level", value: nil)
            }
            MeasurementRow(label: "Pronunciation, accuracy, fluency", value: nil)
            Text("Pronunciation scoring isn't connected yet, so no score is shown.")
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("takeSummary")
    }
}
