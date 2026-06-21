import Foundation

/// Deterministic progress aggregates over real sessions. Pure functions over
/// `[WorkoutSetHistoryRow]` so they're unit-testable and **no AI ever touches a
/// number**. Canonical-only: every series is keyed by `exercise_id`; `family_key`
/// is never used to aggregate, so progression and PRs never collapse across
/// variations (§ PR 5).
enum ProgressAnalytics {

    /// Epley e1RM drops sets above this rep count, where the 1RM estimate is
    /// unreliable. Single-sourced with PR detection (§4) via `OneRepMax`.
    static let e1rmRepCap = OneRepMax.repCap

    /// One charted value for a session (an e1RM point, a volume bar, a reps point).
    struct SessionValue: Equatable, Identifiable {
        let sessionID: Int64
        let startedAt: Date
        let value: Double
        var id: Int64 { sessionID }
    }

    /// A per-muscle weekly hard-set tally — one stacked-bar segment.
    struct MuscleWeekCount: Equatable, Identifiable {
        let weekStart: Date
        let muscle: String          // "Untagged" when the exercise has no primary muscle
        let hardSets: Int
        var id: String { "\(Int(weekStart.timeIntervalSince1970))-\(muscle)" }
    }

    /// An exercise present in history, for the picker. `isBodyweight` means its
    /// sets are predominantly bodyweight/unspecified, so it gets a reps trend
    /// instead of e1RM/volume — no empty Progress tab for calisthenics.
    struct ExerciseOption: Equatable, Identifiable {
        let id: Int64               // exercise_id (the canonical identity)
        let name: String
        let isBodyweight: Bool
        let setCount: Int
    }

    /// Exercises present in history, most-logged first (ties broken by name).
    static func exercises(_ rows: [WorkoutSetHistoryRow]) -> [ExerciseOption] {
        struct Tally { var name = ""; var total = 0; var external = 0; var bodyweightish = 0 }
        var byID: [Int64: Tally] = [:]
        for row in rows {
            var tally = byID[row.exerciseID] ?? Tally()
            tally.name = row.exerciseName
            tally.total += 1
            switch row.load.kind {
            case .external, .bodyweightPlus, .assisted: tally.external += 1
            case .bodyweight, .unspecified: tally.bodyweightish += 1
            }
            byID[row.exerciseID] = tally
        }
        return byID.map { id, tally in
            ExerciseOption(id: id, name: tally.name,
                           isBodyweight: tally.bodyweightish > tally.external,
                           setCount: tally.total)
        }
        .sorted { ($0.setCount, $1.name) > ($1.setCount, $0.name) }
    }

    /// e1RM per session for one exercise: max over `.external` sets of
    /// `amount * (1 + reps/30)` (Epley), dropping reps above the cap. One point
    /// per session.
    static func e1RMSeries(_ rows: [WorkoutSetHistoryRow], exerciseID: Int64,
                           policy: AnalyticsPolicy) -> [SessionValue] {
        sessionSeries(rows, exerciseID: exerciseID, policy: policy) { sets in
            sets.compactMap { row -> Double? in
                guard policy.countsTowardVolume(row.setType),   // working-equivalent only — not warmups/backoffs
                      row.load.kind == .external, let amount = row.load.amount, row.reps <= e1rmRepCap else { return nil }
                return OneRepMax.epley(weight: amount, reps: row.reps)
            }.max()
        }
    }

    /// Volume per session: sum of `amount * reps` over `.external` working sets.
    /// One bar per session.
    static func volumeSeries(_ rows: [WorkoutSetHistoryRow], exerciseID: Int64,
                             policy: AnalyticsPolicy) -> [SessionValue] {
        sessionSeries(rows, exerciseID: exerciseID, policy: policy) { sets in
            let volume = sets.reduce(0.0) { total, row in
                guard policy.countsTowardVolume(row.setType),
                      row.load.kind == .external, let amount = row.load.amount else { return total }
                return total + amount * Double(row.reps)
            }
            return volume > 0 ? volume : nil
        }
    }

    /// Max reps per session over working sets — the trend for bodyweight/
    /// calisthenics lifts where e1RM and external volume are meaningless.
    static func repsSeries(_ rows: [WorkoutSetHistoryRow], exerciseID: Int64,
                           policy: AnalyticsPolicy) -> [SessionValue] {
        sessionSeries(rows, exerciseID: exerciseID, policy: policy) { sets in
            sets.filter { policy.countsTowardVolume($0.setType) }.map { Double($0.reps) }.max()
        }
    }

    /// Per-muscle weekly hard sets (primary muscle only at launch), bucketed by
    /// ISO week. `secondary_muscles` is stored but deliberately not counted yet.
    static func muscleWeeklyHardSets(_ rows: [WorkoutSetHistoryRow], policy: AnalyticsPolicy,
                                     calendar: Calendar = Calendar(identifier: .iso8601)) -> [MuscleWeekCount] {
        var tally: [Date: [String: Int]] = [:]
        for row in rows {
            guard policy.countsTowardTrend(feel: row.sessionFeel, isDeload: row.sessionIsDeload),
                  policy.isHardSet(setType: row.setType, rir: row.rir),
                  let date = WorkoutStore.date(row.startedAt),
                  let weekStart = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { continue }
            tally[weekStart, default: [:]][row.primaryMuscle ?? "Untagged", default: 0] += 1
        }
        return tally.flatMap { week, muscles in
            muscles.map { MuscleWeekCount(weekStart: week, muscle: $0.key, hardSets: $0.value) }
        }
        .sorted { ($0.weekStart, $0.muscle) < ($1.weekStart, $1.muscle) }
    }

    /// Filter to one exercise and policy-eligible sessions, group by session,
    /// reduce each session's sets to a value (nil = no point), sorted chronologically.
    private static func sessionSeries(_ rows: [WorkoutSetHistoryRow], exerciseID: Int64,
                                      policy: AnalyticsPolicy,
                                      reduce: ([WorkoutSetHistoryRow]) -> Double?) -> [SessionValue] {
        let eligible = rows.filter {
            $0.exerciseID == exerciseID && policy.countsTowardTrend(feel: $0.sessionFeel, isDeload: $0.sessionIsDeload)
        }
        return Dictionary(grouping: eligible, by: \.sessionID).compactMap { sessionID, sets -> SessionValue? in
            guard let value = reduce(sets), let started = sets.first.flatMap({ WorkoutStore.date($0.startedAt) }) else { return nil }
            return SessionValue(sessionID: sessionID, startedAt: started, value: value)
        }
        .sorted { $0.startedAt < $1.startedAt }
    }
}
