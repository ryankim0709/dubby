import SwiftUI

/// Practice stats computed from the dubs saved on this device.
struct PracticeProgressView: View {
    let dubs: LoadState<[SavedDub]>
    let folder: URL
    let onRetry: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your progress")
                    .dubFont(24, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.top, 8)
                LoadStateContent(state: dubs, retry: onRetry) { dubs in
                    if dubs.isEmpty {
                        EmptyStateView(
                            systemImage: "flame",
                            title: "Start your streak",
                            message: "Finish a dub today and your streak, totals, and measured takes appear here."
                        )
                    } else {
                        ProgressSummary(dubs: dubs, folder: folder, today: .now, calendar: .current)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .background(Palette.background)
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct ProgressSummary: View {
    let dubs: [SavedDub]
    let folder: URL
    let today: Date
    let calendar: Calendar

    private var dates: [Date] { dubs.map(\.createdAt) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            streakCard
            AdaptiveStack(rowAlignment: .top, spacing: 8) {
                StatTile(value: "\(dubs.count)", label: "Scenes dubbed")
                StatTile(value: "\(dubs.reduce(0) { $0 + $1.linesDubbed })", label: "Lines recorded")
                StatTile(value: "\(Int((dubs.reduce(0) { $0 + $1.sceneSeconds } / 60).rounded(.up)))m", label: "Of scenes dubbed")
            }
            measuredCard
            Text("Recent dubs")
                .dubFont(18, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
            VStack(spacing: 8) {
                ForEach(dubs.prefix(5)) { dub in
                    HStack(spacing: 12) {
                        VideoThumbnail(url: DubLibrary.videoURL(for: dub, in: folder))
                            .frame(width: 72, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dub.sceneTitle)
                                .dubFont(14, weight: .medium)
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(1)
                            Text("as \(dub.characterName) · \(dub.createdAt.formatted(.relative(presentation: .named)))")
                                .dubFont(12, weight: .regular)
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text("\(dub.linesDubbed)/\(dub.totalLines)")
                            .dubFont(14, weight: .semibold)
                            .monospacedDigit()
                            .foregroundStyle(Palette.accentText)
                            .accessibilityLabel("\(dub.linesDubbed) of \(dub.totalLines) lines")
                    }
                    .padding(12)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var measuredCard: some View {
        let practice = MeasuredPractice(dubs: dubs)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Measured takes")
                .dubFont(18, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
            if practice.hasMeasurements {
                MeasurementRow(label: "Takes measured", value: "\(practice.measuredTakes)")
                MeasurementRow(label: "Fit their line", value: "\(practice.takesFittingLine) of \(practice.measuredTakes)")
                MeasurementRow(label: "Clear voice picked up", value: "\(practice.takesWithVoice) of \(practice.measuredTakes)")
            } else {
                MeasurementRow(label: "Take length and mic level", value: nil)
            }
            if practice.dubsWithoutMeasurements > 0 {
                Text("\(practice.dubsWithoutMeasurements) saved \(practice.dubsWithoutMeasurements == 1 ? "dub was" : "dubs were") recorded before takes were measured and \(practice.dubsWithoutMeasurements == 1 ? "isn't" : "aren't") counted here.")
                    .dubFont(12, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
            }
            MeasurementRow(label: "Pronunciation, accuracy, fluency", value: nil)
            Text("Pronunciation scoring isn't connected yet, so progress shows only what the device measured: take length and mic level.")
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("measuredTakes")
    }

    private var streakCard: some View {
        let streak = PracticeStats.currentStreak(dates: dates, today: today, calendar: calendar)
        let week = PracticeStats.week(dates: dates, today: today, calendar: calendar)
        let dubbedToday = week.contains { $0.isToday && $0.hasDub }
        return VStack(alignment: .leading, spacing: 16) {
            AdaptiveStack(rowAlignment: .firstTextBaseline, spacing: 4) {
                Text(streak > 0 ? "🔥 \(streak)-day streak" : "No streak yet")
                    .dubFont(20, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Text("Best: \(PracticeStats.bestStreak(dates: dates, calendar: calendar)) days")
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
            }
            HStack {
                ForEach(week) { day in
                    VStack(spacing: 6) {
                        ZStack {
                            if day.hasDub {
                                Circle().fill(Palette.accent)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Palette.onAccent)
                            } else {
                                Circle().fill(Palette.segmentInactive)
                            }
                            if day.isToday {
                                Circle()
                                    .strokeBorder(Palette.accentText, lineWidth: 2)
                                    .padding(-4)
                            }
                        }
                        .frame(width: 32, height: 32)
                        Text(day.label)
                            .dubFont(12, weight: day.isToday ? .semibold : .regular)
                            .foregroundStyle(day.isToday ? Palette.accentText : Palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(day.date.formatted(.dateTime.weekday(.wide))), \(day.hasDub ? "dubbed" : "no dub")")
                }
            }
            Text(dubbedToday ? "Today's dub is done. Come back tomorrow to keep it going." : "Dub one scene today to keep your streak alive.")
                .dubFont(14, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .dubFont(22, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
            Text(label)
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}
