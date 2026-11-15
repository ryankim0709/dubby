import SwiftUI

/// The dub's score sheet on the result screen: progress while takes upload and score, then the dub score and
/// each line's result.
struct DubScoreCard: View {
    let state: DubScoringModel.State?
    let onRetry: () -> Void
    let onPractise: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dub score")
                .dubFont(16, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            switch state {
            case nil, .uploading:
                progress("Sending your takes for scoring…")
            case .scoring(let sheet):
                progress(sheet.map { "Scoring your lines… \($0.linesFinished) of \(Int($0.linesDubbed))" } ?? "Scoring your lines…")
            case .complete(let sheet):
                complete(sheet)
            case .failed(let message):
                Text(message)
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
                Button("Try scoring again", action: onRetry)
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("retryScoring")
            case .notScored(let reason):
                Text(reason)
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("dubScoreCard")
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(Palette.accentText)
            Text(label)
                .dubFont(14, weight: .regular)
                .foregroundStyle(Palette.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func complete(_ sheet: DubScoreSheet) -> some View {
        if let dubScore = sheet.dubScore {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(dubScore))")
                    .dubFont(40, weight: .semibold)
                    .foregroundStyle(Palette.accentText)
                Text("out of 100")
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("dubScore")
            MeasurementRow(label: "Words said", value: sheet.wordAccuracy.map { "\(Int($0))" })
            MeasurementRow(label: "Timing", value: sheet.timingFit.map { "\(Int($0))" })
        } else {
            Text("None of your lines could be scored.")
                .dubFont(14, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
        }
        ForEach(sheet.lines) { line in
            LineScoreRow(line: line)
        }
        Text("Scored on the words you said and how well each take fit its line. Pronunciation isn't scored yet.")
            .dubFont(12, weight: .regular)
            .foregroundStyle(Palette.textSecondary)
        // The tutor works from scored lines and silent takes; failures and unsupported languages give it nothing to practise.
        if sheet.lines.contains(where: { $0.status == .scored || $0.reason == "no_speech" }) {
            Button(action: onPractise) {
                Label("Practise with your tutor", systemImage: "waveform")
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityIdentifier("practiseWithTutor")
            Text("A live AI tutor talks you through these lines. Your voice is sent to OpenAI during the call.")
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

private struct LineScoreRow: View {
    let line: DubScoreSheet.Line

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(line.referenceText)
                    .dubFont(14, weight: .medium)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(line.lineScore.map { "\(Int($0))" } ?? "–")
                    .dubFont(16, weight: .semibold)
                    .foregroundStyle(line.lineScore == nil ? Palette.textSecondary : Palette.accentText)
            }
            if let detail {
                Text(detail)
                    .dubFont(12, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { Divider().overlay(Palette.divider) }
        .accessibilityElement(children: .combine)
    }

    /// What to work on for this line: the words that differed, or why it has no score.
    private var detail: String? {
        switch line.status {
        case .queued:
            return "Still scoring."
        case .failed:
            return "This take couldn't be scored."
        case .unscorable:
            switch line.reason {
            case "no_speech": return "No speech was heard in this take."
            case "unsupported_locale": return "Scoring isn't available for this language yet."
            default: return "This take couldn't be scored."
            }
        case .scored:
            let issues = line.words.compactMap { word -> String? in
                switch word.textStatus {
                case .matched: nil
                case .substituted: "said “\(word.recognized ?? "")” for “\(word.expected ?? "")”"
                case .omitted: "missed “\(word.expected ?? "")”"
                case .inserted: "added “\(word.recognized ?? "")”"
                }
            }
            return issues.isEmpty ? "Every word, as written." : issues.prefix(3).joined(separator: " · ")
        }
    }
}
