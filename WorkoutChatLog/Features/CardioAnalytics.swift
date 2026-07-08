import Foundation

/// Deterministic cardio trend aggregates — the cardio counterpart to
/// `SupplementAnalytics`/`ProgressAnalytics`. Pure functions over `[CardioEntry]`
/// so the math is unit-testable and no AI ever touches a number. Honest by
/// construction: minutes come only from bouts that actually logged a duration
/// (never fabricated), distances are summed **per logged unit and never
/// converted**, and activities group by the stored string verbatim (canonical
/// display names whenever the parser matched) — no fuzzy merging in numbers.
enum CardioAnalytics {

    /// One stacked-bar segment: minutes of one activity in one ISO week.
    struct WeekMinutes: Equatable, Identifiable {
        let weekStart: Date
        let activity: String
        let minutes: Double
        var id: String { "\(Int(weekStart.timeIntervalSince1970))-\(activity)" }
    }

    /// A per-activity rollup for the summary rows under the chart.
    struct ActivitySummary: Equatable, Identifiable {
        let activity: String
        let bouts: Int                                     // every bout, metric-less included
        let totalSeconds: Int                              // 0 when no bout carried a duration
        let distanceByUnit: [CardioDistanceUnit: Double]   // verbatim units, no conversion
        var id: String { activity }
    }

    /// Weekly minutes per activity over the trailing window, bucketed by ISO week
    /// (the same convention as `ProgressAnalytics.muscleWeeklyHardSets`). Bouts
    /// without a duration are excluded — the chart shows only real minutes.
    static func weeklyMinutes(entries: [CardioEntry], today: Date, windowDays: Int = 30,
                              calendar: Calendar = Calendar(identifier: .iso8601)) -> [WeekMinutes] {
        var tally: [Date: [String: Double]] = [:]
        for entry in inWindow(entries, today: today, windowDays: windowDays) {
            guard let seconds = entry.durationSeconds, seconds > 0,
                  let weekStart = calendar.dateInterval(of: .weekOfYear, for: entry.loggedAt)?.start else { continue }
            tally[weekStart, default: [:]][entry.activity, default: 0] += Double(seconds) / 60
        }
        return tally.flatMap { week, activities in
            activities.map { WeekMinutes(weekStart: week, activity: $0.key, minutes: $0.value) }
        }
        .sorted { ($0.weekStart, $0.activity) < ($1.weekStart, $1.activity) }
    }

    /// Per-activity totals over the trailing window, most-done activity first
    /// (ties broken by name). Distances stay in the units they were logged in.
    static func activitySummaries(entries: [CardioEntry], today: Date,
                                  windowDays: Int = 30) -> [ActivitySummary] {
        struct Tally { var bouts = 0; var seconds = 0; var distance: [CardioDistanceUnit: Double] = [:] }
        var byActivity: [String: Tally] = [:]
        for entry in inWindow(entries, today: today, windowDays: windowDays) {
            var tally = byActivity[entry.activity] ?? Tally()
            tally.bouts += 1
            tally.seconds += entry.durationSeconds ?? 0
            if let distance = entry.distance, distance > 0, let unit = entry.distanceUnit {
                tally.distance[unit, default: 0] += distance
            }
            byActivity[entry.activity] = tally
        }
        return byActivity.map { activity, tally in
            ActivitySummary(activity: activity, bouts: tally.bouts,
                            totalSeconds: tally.seconds, distanceByUnit: tally.distance)
        }
        .sorted { ($0.bouts, $1.activity) > ($1.bouts, $0.activity) }
    }

    /// The start of the trailing `windowDays` window ending `today` (inclusive —
    /// a 30-day window spans today and the 29 days before it). Single-sourced so
    /// the model's store fetch bound and the analytics filter can never disagree
    /// about which edge-day bouts are in.
    static func windowStart(today: Date, windowDays: Int) -> Date? {
        Calendar.current.date(byAdding: .day, value: -(windowDays - 1),
                              to: Calendar.current.startOfDay(for: today))
    }

    /// Entries logged within the trailing window.
    private static func inWindow(_ entries: [CardioEntry], today: Date, windowDays: Int) -> [CardioEntry] {
        guard let start = windowStart(today: today, windowDays: windowDays) else { return entries }
        return entries.filter { $0.loggedAt >= start && $0.loggedAt <= today }
    }
}
