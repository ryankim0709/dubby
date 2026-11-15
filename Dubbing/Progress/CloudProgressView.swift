import SwiftUI

/// What the coach has measured for the signed-in learner, one card per progress series.
struct CloudProgressSection: View {
    let account: AccountModel
    @State private var model: CloudProgressModel

    init(account: AccountModel) {
        self.account = account
        _model = State(initialValue: CloudProgressModel(account: account))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Coach progress")
                .dubFont(18, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            switch model.state {
            case .loading:
                ProgressView()
                    .tint(Palette.accentText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .accessibilityLabel("Loading coach progress")
            case .failed(let message):
                VStack(spacing: 12) {
                    EmptyStateView(systemImage: "exclamationmark.triangle", title: "Couldn't load coach progress", message: message)
                        .accessibilityIdentifier("cloudProgressFailed")
                    Button("Try again") { Task { await model.refresh() } }
                        .buttonStyle(OutlineCapsuleButtonStyle())
                        .accessibilityIdentifier("cloudProgressRetry")
                }
            case .loaded(let series) where series.isEmpty:
                EmptyStateView(
                    systemImage: "chart.line.uptrend.xyaxis",
                    title: "Nothing measured yet",
                    message: "Once your coach has scored a take, your progress shows up here."
                )
                .accessibilityIdentifier("cloudProgressEmpty")
            case .loaded(let series):
                ForEach(series) { SeriesCard(summary: $0) }
            }
        }
        .task(id: account.phase.isSignedIn) { await model.refresh() }
    }
}

private struct SeriesCard: View {
    let summary: CloudSeriesSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary.localeName)
                .dubFont(16, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
            Text(summary.isAcoustic ? "Measured from your speech." : "Compared with the script's transcript, so there are no pronunciation or fluency scores.")
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
            Text("\(summary.volume.attempts) \(summary.volume.attempts == 1 ? "attempt" : "attempts") on \(summary.volume.lines) \(summary.volume.lines == 1 ? "line" : "lines") over \(summary.volume.practiceDays) \(summary.volume.practiceDays == 1 ? "day" : "days"); \(summary.volume.scorableAttempts) scored.")
                .dubFont(14, weight: .regular)
                .foregroundStyle(Palette.textPrimary)
            ForEach(summary.skills, id: \.metric) { skill in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(skill.metric.title)
                        Spacer()
                        Text("\(skill.latest)").monospacedDigit().fontWeight(.semibold)
                    }
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textPrimary)
                    if let change = skill.change {
                        Text(change)
                            .dubFont(12, weight: .regular)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(summary.unmeasured, id: \.metric) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.metric.title)
                    Spacer()
                    Text("Not measured")
                }
                .dubFont(14, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.metric.title), not measured. \(item.reason)")
            }
            if !summary.words.isEmpty {
                Text("Words to practise")
                    .dubFont(14, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
                ForEach(summary.words, id: \.word) { word in
                    HStack {
                        Text(word.word).fontWeight(.medium)
                        Spacer()
                        Text(word.detail)
                    }
                    .dubFont(12, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("cloudProgressSeries")
    }
}
