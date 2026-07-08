import Foundation

/// What the Home Screen widget renders — a tiny, app-internal DTO so the widget is
/// decoupled from the store's read types (it never sees `OpenSession`,
/// `WorkoutSetHistoryRow`, etc.). Produced by `WorkoutWidgetReader` from the shared
/// SQLite file; the widget only reads.
enum WidgetWorkoutSnapshot: Equatable {
    /// A workout is in progress (an open session), with its running set count.
    case current(sets: Int)
    /// No open session; the most recently finished workout.
    case last(name: String?, endedAt: Date, sets: Int)
    /// No open session and the most recent thing logged is a cardio bout. Raw
    /// fields, not a preformatted string — the view formats through the shared
    /// `CardioFormat`, so the widget and History can never render differently.
    case lastCardio(activity: String, durationSeconds: Int?, distance: Double?,
                    distanceUnit: CardioDistanceUnit?, loggedAt: Date)
    /// Nothing logged yet (or the store can't be read).
    case empty
}
