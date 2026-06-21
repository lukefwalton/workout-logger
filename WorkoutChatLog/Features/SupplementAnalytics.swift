import Foundation

/// Pure, deterministic supplement trend aggregates over a trailing window — the
/// supplement counterpart to `ProgressAnalytics`. No store access, no UI: takes the
/// configured list plus raw intake rows and the reference "today", returns adherence,
/// current streak, and (for grams-tracking supplements) a grams series. Unit-tested
/// directly; nothing here is estimated or fabricated.
enum SupplementAnalytics {
    struct Trend: Identifiable, Equatable {
        let supplementID: Int64
        let name: String
        let tracksGrams: Bool
        let windowDays: Int
        let daysTaken: Int
        let currentStreak: Int
        var id: Int64 { supplementID }
        /// 0…1 share of the window's days taken.
        var adherence: Double { windowDays == 0 ? 0 : Double(daysTaken) / Double(windowDays) }
    }

    struct GramsPoint: Identifiable, Equatable {
        let day: Date
        let grams: Double
        var id: TimeInterval { day.timeIntervalSince1970 }
    }

    /// Per-supplement trend over the last `windowDays` days ending `today`.
    static func trends(supplements: [Supplement],
                       history: [SupplementIntake],
                       today: Date,
                       windowDays: Int = 30,
                       calendar: Calendar = .current) -> [Trend] {
        var takenDays: [Int64: Set<String>] = [:]
        for intake in history {
            takenDays[intake.supplementID, default: []].insert(intake.day)
        }
        let windowSet = Set((0..<windowDays).map { SupplementDay.key(daysAgo: $0, from: today, calendar: calendar) })
        let todayKey = SupplementDay.key(for: today, calendar: calendar)

        return supplements.map { supplement in
            let taken = takenDays[supplement.id] ?? []
            let daysTaken = taken.intersection(windowSet).count

            // Current streak: consecutive taken days ending today — or ending
            // yesterday when today isn't checked yet, so the streak stays "alive"
            // through the current day rather than reading 0 all morning.
            var streak = 0
            var offset = taken.contains(todayKey) ? 0 : 1
            while taken.contains(SupplementDay.key(daysAgo: offset, from: today, calendar: calendar)) {
                streak += 1
                offset += 1
            }

            return Trend(supplementID: supplement.id,
                         name: supplement.name,
                         tracksGrams: supplement.tracksGrams,
                         windowDays: windowDays,
                         daysTaken: daysTaken,
                         currentStreak: streak)
        }
    }

    /// The grams series for one supplement over the window, oldest first (only days
    /// with a recorded grams value).
    static func gramsSeries(supplementID: Int64,
                            history: [SupplementIntake],
                            today: Date,
                            windowDays: Int = 30,
                            calendar: Calendar = .current) -> [GramsPoint] {
        let windowSet = Set((0..<windowDays).map { SupplementDay.key(daysAgo: $0, from: today, calendar: calendar) })
        return history.compactMap { intake -> GramsPoint? in
            guard intake.supplementID == supplementID,
                  windowSet.contains(intake.day),
                  let grams = intake.grams, grams > 0,
                  let date = SupplementDay.date(fromKey: intake.day, calendar: calendar) else { return nil }
            return GramsPoint(day: date, grams: grams)
        }.sorted { $0.day < $1.day }
    }
}
