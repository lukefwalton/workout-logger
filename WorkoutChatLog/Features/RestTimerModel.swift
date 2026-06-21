import Foundation
import Combine

/// The rest timer's logic and published state (spec §4), kept out of the view so
/// the countdown state machine and mm:ss formatting are unit-testable without a
/// running UI or the `UserNotifications` framework. The actual background alert is
/// delegated to a `RestTimerNotifier` (gated behind a protocol + fake).
///
/// `@MainActor` because it owns published UI state and drives a timer on the main
/// run loop. The clock is injectable so "time passes" is testable deterministically.
///
/// Doctrine: notification permission is requested **in context** — the first time
/// the user starts a timer — never at launch (App Review). A denied permission only
/// suppresses the background alert; the in-app countdown still runs to completion.
@MainActor
final class RestTimerModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case finished
    }

    @Published private(set) var phase: Phase = .idle
    /// Whole seconds left while running (0 otherwise). Drives the mm:ss label.
    @Published private(set) var remainingSeconds: Int = 0

    /// The user's chosen rest length for the next start, in seconds.
    @Published var selectedDuration: Int

    private let notifier: RestTimerNotifier
    private let now: () -> Date
    private var endsAt: Date?
    private var ticker: AnyCancellable?
    /// Handle to the most recent in-context permission/schedule task, exposed so
    /// tests can await the fire-and-forget work deterministically. Production never
    /// reads it.
    private(set) var notificationTask: Task<Void, Never>?
    /// Monotonic token so a slow permission/schedule task from a *previous* timer
    /// can't schedule a stale "rest's over" alert after a restart or cancel. Each
    /// `start` claims the next token; the task checks it's still current before
    /// scheduling. Mutated/read on the main actor, so the check is race-free.
    private var notificationGeneration = 0
    /// The identifier of the rest-end request the current timer scheduled (or will).
    /// Kept so stop/restart can cancel **that exact request synchronously** by id —
    /// no async enumeration — closing the already-scheduled-old-alert window.
    private var currentNotificationToken: String?
    /// Drives a periodic tick while running. Injectable so tests don't wait in real
    /// time — they call `tick(at:)` directly.
    private let tickInterval: TimeInterval

    init(notifier: RestTimerNotifier = RestTimerNotifierFactory.make(),
         selectedDuration: Int = RestTimerPreferences.defaultDurationSeconds,
         now: @escaping () -> Date = Date.init,
         tickInterval: TimeInterval = 0.5) {
        self.notifier = notifier
        self.selectedDuration = selectedDuration
        self.now = now
        self.tickInterval = tickInterval
    }

    var isRunning: Bool { phase == .running }

    /// mm:ss for the current remaining time, e.g. "1:30" or "0:05".
    var display: String { Self.mmss(remainingSeconds) }

    /// Start (or restart) the rest countdown for `seconds` (defaults to the
    /// selected duration). Requests notification authorization **lazily** the first
    /// time, then schedules the background "rest's over" alert only if granted —
    /// the countdown itself runs regardless. Returns immediately; the async permission
    /// work happens in a task and never blocks the timer.
    func start(seconds: Int? = nil) {
        let duration = seconds ?? selectedDuration
        guard duration > 0 else { return }
        // Close the stale-alert window on restart: synchronously drop the previous
        // timer's pending OS notification by its exact id (no async enumeration), and
        // invalidate its in-flight task, *before* scheduling the new one — so an old
        // "rest's over" can't fire in the gap.
        retirePreviousNotification()
        let start = now()
        endsAt = start.addingTimeInterval(TimeInterval(duration))
        phase = .running
        remainingSeconds = duration
        startTicking()
        scheduleNotification()
    }

    /// Stop the timer early and clear it (user finished resting, or dismissed it).
    /// Cancels any pending background alert and invalidates any in-flight permission/
    /// schedule task so it can't land a stale alert after this cancel.
    func cancel() {
        endsAt = nil
        phase = .idle
        remainingSeconds = 0
        stopTicking()
        retirePreviousNotification()
    }

    /// Synchronously retire the current timer's scheduled (or scheduling) alert:
    /// bump the generation (so any in-flight schedule task drops its result), cancel
    /// that task, and remove the pending request **by its exact id** so an
    /// already-scheduled near-expiry alert can't slip through. Shared by stop and
    /// restart.
    private func retirePreviousNotification() {
        notificationGeneration += 1
        notificationTask?.cancel()
        if let token = currentNotificationToken {
            notifier.cancelScheduledRestEnd(token: token)
            currentNotificationToken = nil
        }
    }

    /// Recompute remaining time and transition to `.finished` at/after the end.
    /// Pure given the injected clock; the periodic ticker calls this, and tests call
    /// it directly with a supplied `Date`.
    func tick(at instant: Date? = nil) {
        guard phase == .running, let endsAt else { return }
        let reference = instant ?? now()
        let remaining = endsAt.timeIntervalSince(reference)
        if remaining <= 0 {
            remainingSeconds = 0
            phase = .finished
            stopTicking()
            // The in-app countdown reached the end while foregrounded, so the pending OS
            // alert (which would fire at the same instant) is now redundant — retire it
            // by its id so the user doesn't also get a background buzz for a rest that
            // already visibly ended.
            if let token = currentNotificationToken {
                notifier.cancelScheduledRestEnd(token: token)
                currentNotificationToken = nil
            }
            notificationTask?.cancel()
        } else {
            // Round up so the label shows "1:30" for the full first second, not "1:29".
            remainingSeconds = Int(remaining.rounded(.up))
        }
    }

    private func startTicking() {
        stopTicking()
        ticker = Timer.publish(every: tickInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    /// Ask for permission in context the first time, then schedule only if granted —
    /// but only while this is still the current timer. A restart/cancel bumps the
    /// generation, so a slow task from a prior timer drops its result instead of
    /// scheduling a stale alert. Failure (denied/unavailable) is silent.
    ///
    /// The alert is scheduled against the **absolute** `endsAt`, with the delay
    /// recomputed *after* authorization returns — so a slow first-run permission
    /// prompt can't push the notification late relative to the in-app countdown.
    private func scheduleNotification() {
        notificationGeneration += 1
        let generation = notificationGeneration
        // A fresh token per schedule, remembered so stop/restart can cancel this exact
        // request synchronously by id. The notifier keys the pending request on it, so a
        // superseded task only ever cancels *its own* request — it can never delete the
        // current timer's alert, even if it lands mid-await inside the notifier.
        let token = UUID().uuidString
        currentNotificationToken = token
        notificationTask = Task { [notifier] in
            // Sequential check (not `isAuthorized() || requestAuthorization()`):
            // the `||` short-circuit makes the right-hand side an autoclosure, and
            // autoclosures don't support `await`. An explicit if/else keeps both
            // suspension points addressable.
            let authorized: Bool
            if await notifier.isAuthorized() {
                authorized = true
            } else {
                authorized = await notifier.requestAuthorization()
            }
            // The user may have restarted or stopped the timer while we awaited the
            // permission prompt; only the current timer gets to schedule.
            guard authorized, generation == self.notificationGeneration, let endsAt = self.endsAt else { return }
            // Recompute from the real end time after the (possibly slow) prompt, so the
            // alert lands when rest actually ends — not `duration` from "Allow".
            let remaining = endsAt.timeIntervalSince(self.now())
            guard remaining > 0 else { return }   // already over by the time they allowed
            await notifier.scheduleRestEnd(after: remaining, token: token)
            // `scheduleRestEnd` itself awaits (auth re-check + center.add), so a
            // cancel/restart can land after the guard above but before the request is
            // registered. Re-check at this true scheduling boundary and remove *this
            // token's* request if the timer moved on — the token scoping guarantees we
            // never touch a newer timer's alert.
            if generation != self.notificationGeneration {
                notifier.cancelScheduledRestEnd(token: token)
            }
        }
    }

    /// Test hook: await the in-context permission/schedule task so assertions don't
    /// race the fire-and-forget work. No-op when nothing is in flight.
    func drainNotificationTask() async {
        await notificationTask?.value
    }

    /// Whole seconds → "m:ss", clamped at zero (never a negative clock).
    static func mmss(_ totalSeconds: Int) -> String {
        let clamped = max(0, totalSeconds)
        return "\(clamped / 60):" + String(format: "%02d", clamped % 60)
    }
}
