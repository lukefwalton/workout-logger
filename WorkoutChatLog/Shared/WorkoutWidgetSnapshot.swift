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
    /// Nothing logged yet (or the store can't be read).
    case empty
}
