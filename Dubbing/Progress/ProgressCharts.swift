import Charts
import SwiftUI

/// Dub scores over time, one point per completed dub, on the score sheet's 0 to 100 scale.
struct DubScoreChart: View {
    let points: [CloudSeriesSummary.DubPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dub scores")
                .dubFont(14, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
            Chart(points) { point in
                LineMark(x: .value("Recorded", point.date), y: .value("Dub score", point.score))
                    .foregroundStyle(Palette.textPrimary)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("Recorded", point.date), y: .value("Dub score", point.score))
                    .foregroundStyle(Palette.textPrimary)
                    .symbolSize(28)
            }
            .chartYScale(domain: 0...100)
            .modifier(ProgressChartAxes())
            .frame(height: 150)
            .accessibilityLabel("Dub scores")
            .accessibilityValue(summary)
        }
        .accessibilityIdentifier("dubScoreChart")
    }

    private var summary: String {
        guard let first = points.first, let last = points.last else { return "" }
        return "\(points.count) dubs, from \(Int(first.score.rounded())) to \(Int(last.score.rounded())) out of 100"
    }
}

/// Word accuracy and timing by practice day: each day's first-try average, which the skills' changes are measured from.
struct SkillTrendChart: View {
    let points: [CloudSeriesSummary.SkillPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Day by day")
                .dubFont(14, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
            Chart(points) { point in
                LineMark(x: .value("Day", point.date, unit: .day), y: .value("Score", point.value))
                    .foregroundStyle(by: .value("Skill", point.metric.title))
                    .lineStyle(by: .value("Skill", point.metric.title))
            }
            .chartForegroundStyleScale([ScoreMetric.wordAccuracy.title: Palette.textPrimary, ScoreMetric.timingFit.title: Palette.textSecondary])
            .chartLineStyleScale([
                ScoreMetric.wordAccuracy.title: StrokeStyle(lineWidth: 2),
                ScoreMetric.timingFit.title: StrokeStyle(lineWidth: 2, dash: [5, 4]),
            ])
            .chartLegend(position: .bottom, alignment: .leading)
            .chartYScale(domain: 0...100)
            .modifier(ProgressChartAxes())
            .frame(height: 170)
            .accessibilityLabel("Word accuracy and timing by day")
        }
        .accessibilityIdentifier("skillTrendChart")
    }
}

/// Quiet axes for the progress charts: hairline gridlines and grey labels on the card's charcoal.
private struct ProgressChartAxes: ViewModifier {
    func body(content: Content) -> some View {
        content
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
                    AxisGridLine().foregroundStyle(Palette.hairline)
                    AxisValueLabel().foregroundStyle(Palette.textSecondary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Palette.hairline)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(Palette.textSecondary)
                }
            }
    }
}
