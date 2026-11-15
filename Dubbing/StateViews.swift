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
    /// The error case's name, without its payload (for example `recordingFailed`), so a test can assert the state.
    let code: String

    init(error: any Error) {
        message = error.localizedDescription
        let denial = error as? DubFlowError
        opensSettings = denial == .microphoneDenied || denial == .speechRecognitionDenied
        code = denial.map { String(String(describing: $0).prefix { $0 != "(" }) } ?? "error"
    }
}

extension View {
    /// Makes a stack addressable as one element while its children stay reachable.
    func containerIdentifier(_ identifier: String) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }
}

/// An invisible element that exposes real UI state through its accessibility value, so a UI test can assert
/// a state without reading prose.
struct StateCarrier: Identifiable {
    let identifier: String
    let value: String

    var id: String { identifier }
}

struct StateCarriers: View {
    let items: [StateCarrier]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier(item.identifier)
                    .accessibilityValue(item.value)
            }
        }
        .allowsHitTesting(false)
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
        .buttonStyle(.dubSecondary)
        .accessibilityIdentifier("openSettings")
    }
}

/// A failure with its recovery: retry the step, and Settings when a permission is off.
struct IssueCard: View {
    let title: String
    let issue: FlowIssue
    let identifier: String
    let value: String
    let retryTitle: String
    let retryIdentifier: String
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
                    Button(retryTitle, action: retry)
                        .buttonStyle(.dubSecondary)
                        .accessibilityIdentifier(retryIdentifier)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .containerIdentifier(identifier)
        .accessibilityValue(value)
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

/// What a shown piece of feedback rests on. Only an acoustic speech measurement may carry a pronunciation score.
nonisolated enum TakeFeedbackBasis: String, Sendable {
    case acoustic
    case scriptAgreement = "script_agreement"
    case none
}

extension TakeMeasurement {
    /// Take length and mic level are the only things measured, and neither says anything about pronunciation,
    /// so there is no pronunciation score to show and none exists in the UI.
    var feedbackBasis: TakeFeedbackBasis { .none }

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
        .overlay { StateCarriers(items: [StateCarrier(identifier: "feedbackBasis", value: measurement.feedbackBasis.rawValue)]) }
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
        .overlay { StateCarriers(items: [StateCarrier(identifier: "feedbackBasis", value: TakeFeedbackBasis.none.rawValue)]) }
    }
}
