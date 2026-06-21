import Foundation

/// Decides whether an open workout session should be adopted as the active
/// session or auto-finished as stale. Pure value: no store, no @Published,
/// no Calendar injection beyond the `gap` parameter. The result is consumed
/// by `TodayModel`, which then performs the actual store write and updates
/// its active-session published state.
///
/// The staleness comparison here is **load-bearing**: a session is stale if
/// either (a) its last set (or start, when there's no set yet) is older than
/// `staleSessionGap`, or (b) the reference time is on a different local day
/// than `now`. Both checks must survive any change — they exist so a workout
/// left open overnight can't absorb tomorrow's sets.
struct SessionReconciler {
    /// A session older than this (since its last set) is treated as stale and
    /// auto-finished so it can't absorb a new day's sets. A different local
    /// calendar day is stale regardless of the gap.
    static let staleSessionGap: TimeInterval = 6 * 60 * 60

    let staleSessionGap: TimeInterval

    init(staleSessionGap: TimeInterval = SessionReconciler.staleSessionGap) {
        self.staleSessionGap = staleSessionGap
    }

    enum Decision: Equatable {
        case adopt(OpenSession)
        case retire(OpenSession)
    }

    /// Decide whether `open` should be adopted as the active session or
    /// retired as stale, given `now`. Uses `Calendar.current` so the "same
    /// local day" check follows the device's timezone — that's intentional;
    /// the gap and the day-boundary together are what keep a forgotten
    /// session from eating tomorrow's first set.
    func decide(_ open: OpenSession, now: Date) -> Decision {
        let reference = open.lastSetAt ?? open.startedAt
        let isStale = now.timeIntervalSince(reference) > staleSessionGap
            || !Calendar.current.isDate(reference, inSameDayAs: now)
        return isStale ? .retire(open) : .adopt(open)
    }
}
