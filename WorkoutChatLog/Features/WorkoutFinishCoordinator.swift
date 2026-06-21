import Foundation

/// Thin coordinator for the best-effort side effects that fire after a workout
/// session closes: write the finished workout to Apple Health (if the user
/// opted in) and reload the widget so it shows the just-finished session as
/// the last workout. Stays separate from `TodayModel` so the model body
/// doesn't have to talk to two collaborators inline.
struct WorkoutFinishCoordinator {
    let health: HealthWorkoutCoordinator

    /// Fire the post-finish effects: spawn the Health write Task (when a real
    /// start exists — fabricated bounds are never mirrored) and reload the
    /// widget timelines. Returns the Health write Task only when one was
    /// spawned, so tests can await it deterministically; the widget reload
    /// always runs, including when `start` is nil. Production callers can
    /// discard the return value.
    @discardableResult
    func finalize(start: Date?, end: Date) -> Task<Void, Never>? {
        let task: Task<Void, Never>? = start.map { startDate in
            Task { await health.recordFinishedSession(start: startDate, end: end) }
        }
        WidgetRefresher.reload()
        return task
    }
}
