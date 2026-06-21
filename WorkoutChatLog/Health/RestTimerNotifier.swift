import Foundation

/// Schedules the local notification that fires when a rest timer ends, behind a
/// protocol so **no `UserNotifications` symbol leaks into always-compiled code** —
/// the Linux CI and the unit tests build without it. The real implementation
/// (`UserNotificationsRestNotifier`) lives entirely inside
/// `#if canImport(UserNotifications)`; tests use `FakeRestTimerNotifier`.
///
/// Doctrine (App Review, `docs/app-store-review-notes.md`): notification
/// permission is requested **in context** — the first time the user starts a rest
/// timer — never at launch. Authorization is its own step from scheduling, so the
/// timer's countdown works fully even when notifications are denied; only the
/// background "rest's over" alert needs permission.
protocol RestTimerNotifier {
    /// Ask the system for notification authorization, returning whether it was
    /// granted. Called lazily, the first time a timer starts. False also covers
    /// UserNotifications-unavailable / request error.
    func requestAuthorization() async -> Bool

    /// Whether the user has already granted notification authorization, without
    /// prompting. Drives whether `start` prompts in context or schedules directly.
    func isAuthorized() async -> Bool

    /// Schedule a single "rest's over" notification `after` seconds from now, keyed on
    /// `token` so a superseded timer's task can later cancel **only its own** request
    /// (never a newer timer's). No-ops (and returns false) when not authorized or
    /// unavailable — the in-app countdown is the source of truth; the notification is
    /// only a background convenience.
    @discardableResult
    func scheduleRestEnd(after seconds: TimeInterval, token: String) async -> Bool

    /// Cancel the pending rest-end notification with this exact `token`. Synchronous
    /// by `token` (not an async enumeration), so stop/restart can retire the current
    /// timer's already-scheduled alert immediately — and a superseded schedule task can
    /// retract a request it added mid-await without disturbing a newer timer's alert.
    func cancelScheduledRestEnd(token: String)
}

/// The stand-in used when UserNotifications isn't compiled in (Linux/CI) or for
/// tests: nothing is authorized and nothing is scheduled, so the countdown logic
/// can be exercised without the framework.
struct NoopRestTimerNotifier: RestTimerNotifier {
    func requestAuthorization() async -> Bool { false }
    func isAuthorized() async -> Bool { false }
    @discardableResult
    func scheduleRestEnd(after seconds: TimeInterval, token: String) async -> Bool { false }
    func cancelScheduledRestEnd(token: String) {}
}

/// Picks the real notifier when the SDK is present, the no-op otherwise. The `#if`
/// is the only place the two worlds meet; callers just get a `RestTimerNotifier`.
enum RestTimerNotifierFactory {
    static func make() -> RestTimerNotifier {
        #if canImport(UserNotifications)
        return UserNotificationsRestNotifier()
        #else
        return NoopRestTimerNotifier()
        #endif
    }
}

/// Rest-timer durations and the user's chosen default, shared by `SettingsView`
/// (`@AppStorage`) and the Today start-rest affordance so both read/write the same
/// preference. Durations are fixed (60/90/120/180s) per spec §4.
enum RestTimerPreferences {
    /// The user's preferred default rest, in **seconds**. `@AppStorage` stores it as
    /// a Double; 0 / unset falls back to `defaultDurationSeconds`.
    static let defaultDurationKey = "settings.restTimer.defaultSeconds"

    /// The fixed menu of rest durations (seconds), spec §4.
    static let durationOptions: [Int] = [60, 90, 120, 180]

    /// The default when the user hasn't chosen one.
    static let defaultDurationSeconds = 90

    /// Resolve a stored preference (possibly 0/unset) to a sensible duration.
    static func resolvedDefault(_ stored: Double) -> Int {
        let seconds = Int(stored)
        return durationOptions.contains(seconds) ? seconds : defaultDurationSeconds
    }
}
