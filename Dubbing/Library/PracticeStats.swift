import Foundation

nonisolated struct WeekDay: Hashable, Sendable, Identifiable {
    let date: Date
    let label: String
    let hasDub: Bool
    let isToday: Bool

    var id: Date { date }
}

/// Counts over the takes whose recordings were measured on this device. Nothing here is a score: a dub saved
/// without measurements contributes no takes, and the UI shows "Not measured" when `hasMeasurements` is false.
nonisolated struct MeasuredPractice: Equatable, Sendable {
    let measuredTakes: Int
    let takesFittingLine: Int
    let takesWithVoice: Int
    let silentTakes: Int
    /// Dubs saved before takes were measured.
    let dubsWithoutMeasurements: Int

    var hasMeasurements: Bool { measuredTakes > 0 }

    init(measurements: [TakeMeasurement]) {
        self.init(measurements: measurements, dubsWithoutMeasurements: 0)
    }

    private init(measurements: [TakeMeasurement], dubsWithoutMeasurements: Int) {
        measuredTakes = measurements.count
        takesFittingLine = measurements.filter(\.fitsLine).count
        takesWithVoice = measurements.filter { $0.level == .quiet || $0.level == .clear }.count
        silentTakes = measurements.filter { $0.level == .silent }.count
        self.dubsWithoutMeasurements = dubsWithoutMeasurements
    }

    init(dubs: [SavedDub]) {
        self.init(
            measurements: dubs.flatMap { $0.takeMeasurements ?? [] },
            dubsWithoutMeasurements: dubs.filter { $0.takeMeasurements == nil }.count
        )
    }
}

/// Practice numbers derived from the dubs the user actually saved.
nonisolated enum PracticeStats {
    /// Consecutive days with a dub, ending today, or yesterday if today has none yet (the streak is still alive).
    static func currentStreak(dates: [Date], today: Date, calendar: Calendar) -> Int {
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        var day = calendar.startOfDay(for: today)
        if !days.contains(day), let yesterday = calendar.date(byAdding: .day, value: -1, to: day) {
            day = yesterday
        }
        var streak = 0
        while days.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    static func bestStreak(dates: [Date], calendar: Calendar) -> Int {
        let days = Set(dates.map { calendar.startOfDay(for: $0) }).sorted()
        var best = 0
        var run = 0
        var previous: Date?
        for day in days {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = day
        }
        return best
    }

    /// The current calendar week, marking days with at least one dub.
    static func week(dates: [Date], today: Date, calendar: Calendar) -> [WeekDay] {
        guard let start = calendar.dateInterval(of: .weekOfYear, for: today)?.start else { return [] }
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        let symbols = calendar.veryShortWeekdaySymbols
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return WeekDay(
                date: date,
                label: symbols[calendar.component(.weekday, from: date) - 1],
                hasDub: days.contains(calendar.startOfDay(for: date)),
                isToday: calendar.isDate(date, inSameDayAs: today)
            )
        }
    }
}
