# 022 — Rest timer

Fourth ergonomics feature (spec §4). A between-sets countdown with a configurable
default duration and an **optional** background notification, asked for in context.

## What shipped

- **`Health/RestTimerNotifier.swift`** — `protocol RestTimerNotifier` (Foundation-only) +
  `NoopRestTimerNotifier` + `RestTimerNotifierFactory`, exactly mirroring the
  `HealthService` gating template. Plus `RestTimerPreferences` (the fixed 60/90/120/180s
  menu, the default-duration `@AppStorage` key, and `resolvedDefault`).
- **`Health/UserNotificationsRestNotifier.swift`** — the real notifier, entirely inside
  `#if canImport(UserNotifications)`, so no `UNUserNotificationCenter` symbol reaches
  always-compiled code. Schedules a single replace-on-restart `UNTimeIntervalNotification`.
- **`Features/RestTimerModel.swift`** — `@MainActor ObservableObject` with the pure
  countdown state machine (`idle → running → finished`), `mmss` formatting, an injectable
  clock, and the in-context permission flow. Exposes `notificationTask` + `drainNotificationTask()`
  so tests await the fire-and-forget permission/schedule work deterministically (the
  `TodayModel.pendingHealthWrite` pattern).
- **UI**: a "Rest timer" duration picker in `SettingsView`; a start-rest affordance in
  `TodayView`'s saved-status section that becomes a live mm:ss countdown, then a "Rest's
  over" prompt.

## Decisions

- **Gated like every other framework** (§ gating discipline): compile gate
  (`#if canImport(UserNotifications)`) **and** runtime authorization check, no SDK symbol
  in always-compiled code, behind a protocol with a fake. The pure logic (which duration,
  mm:ss, the countdown) is fully unit-tested here; the actual notification *delivery* is a
  device-acceptance step, flagged unverified.
- **Permission is requested in context, never at launch** (App Review,
  `docs/app-store-review-notes.md`): the first `start` asks for authorization, then
  schedules only if granted. A denial is silent — **the in-app countdown still runs to
  completion**; only the background alert needs permission. Tested both ways
  (granted → schedules; denied → runs, schedules nothing; already-authorized → no
  re-prompt).
- **The clock is injected.** "Time passes" is tested by advancing a captured `Date` and
  calling `tick(at:)`, so no test waits in real time. Production drives `tick()` from a
  `Timer.publish` ticker on the main run loop.
- **mm:ss rounds up** so a full first second reads "1:30", not "1:29", and clamps at zero
  (never a negative clock).
- **Durations are fixed** (60/90/120/180s) per spec; an off-menu or unset stored value
  resolves to 90s.

## Review round (later) — diagnosable notifier failures

A reviewer noted that `UserNotificationsRestNotifier`'s auth/scheduling failures collapsed
to `false` with no surfaced context, so a *real* `UNUserNotificationCenter` failure would
look identical to "the user declined / notifications just don't happen" in a device report.
Fixed by mirroring the `HealthKitService` precedent (`learnings/014`): an `os.Logger`
(subsystem = bundle id, category `RestTimer`) logs the auth-request throw and the
`center.add` throw at `.error` (`.public` — a notification error carries no user content),
and the not-authorized skip at `.info`. The feature still degrades silently for the user
(the in-app countdown is the source of truth); the failures are now visible in the unified
log without a DEBUG `print`.

## Validation (logic runs here; UI + delivery not compiled — Linux, no Xcode)

- **State machine + mm:ss prototyped in Python** first; all transitions pass (start,
  count-down, finish-at-zero, clamp-past-end, cancel→idle, zero-duration no-op, formatting
  incl. negative/rounding).
- **Tests written** (correct-by-inspection, **not run here**): `RestTimerModelTests` (the
  machine, formatting, and the three permission paths via `FakeRestTimerNotifier` — no
  `UserNotifications` import), `RestTimerPreferences.resolvedDefault` fallback.
- The real `UNUserNotificationCenter` scheduling/delivery and the SwiftUI controls are a
  human-on-device acceptance step.

## Review round (surmado) — stale-notification race + persistent countdown

Two fixes (both 🟡 + a UX question, all valid):

- **Stale notification on cancel/restart.** `start`/`cancel` didn't invalidate the
  in-flight permission/schedule task, so a slow prompt from a *previous* timer could
  schedule a "rest's over" alert for a dead one. Fixed with a monotonic
  `notificationGeneration` (the same guard `TodayModel.runParse` uses): `cancel` bumps it
  and cancels the task; the task re-checks `generation == notificationGeneration` on the
  main actor *after* the await hop before scheduling. Tests:
  cancel-while-in-flight schedules nothing; restart schedules only the latest duration.
- **Countdown hidden by status changes.** The timer UI only rendered in `.saved`, so a new
  parse hid an active rest (the object kept running). The running/finished countdown now
  renders independently (gated on `restTimer.phase != .idle`), while the contextual
  "Start rest" prompt stays in the saved-status branch.

## Review round (later) — first-run prompt timing

🟡: the countdown started immediately but the notification was scheduled *after* the
permission prompt, still using the full `duration` — so a slow first-run "Allow" (10–20s)
would fire the alert that much late. Fixed by scheduling against the **absolute** `endsAt`:
`scheduleNotification()` recomputes the delay (`endsAt − now()`) *after* authorization
returns, so the alert lands when rest actually ends (and no-ops if rest already elapsed
during the prompt). Added `testSlowPermissionPromptSchedulesAgainstTheRealEndNotFullDuration`.

## Review round (later) — restart closes the stale-alert window synchronously

🟡: restart rescheduled via the async task but didn't drop the *previous* pending OS
notification until that task ran, leaving a small window where an old "rest's over" could
fire. `start()` now cancels the pending notification (and invalidates the prior task +
bumps the generation) **synchronously** before scheduling the new one. Added
`testRestartCancelsThePreviousPendingNotificationImmediately`.

## Review round (later) — token-scoped scheduling closes the mid-await race

🔴: the generation guard ran *before* `scheduleRestEnd`, but the notifier then does its own
awaits (`isAuthorized()`, `center.add()`); a cancel/restart landing in that window could let
a stale task add the request *after* the synchronous cancel had nothing to remove. A naive
"re-check + cancel after the await" first attempt was **worse** — with a single shared
request id, a stale task could delete the *current* timer's alert (traced in Python). Fix:
**per-start tokens** — each schedule uses a fresh `UUID`, the notifier keys the request on
it, and the post-await re-check cancels **only its own token**, so a superseded task can
never touch a newer timer's alert. Validated every interleaving in Python;
`testTokenScopedCancelRemovesOnlyThatRequest` pins it.

## Review round (later) — synchronous cancel-by-id for the already-scheduled alert

🔴 (follow-on): the token fix covered the *in-flight scheduling* race, but stop/restart
still cleared the *already-scheduled* request via an async enumeration
(`getPendingNotificationRequests`), so a near-expiry old alert could fire before the callback
removed it. Fix: the **model remembers `currentNotificationToken`** and stop/restart
(`retirePreviousNotification`) cancels that exact id **synchronously**
(`removePendingNotificationRequests(withIdentifiers:)` — no enumeration), a hard guarantee
that the old request is gone before `start()` returns. The enumerating
`cancelAllScheduledRestEnd()` was removed; the protocol is just
`scheduleRestEnd(after:token:)` + `cancelScheduledRestEnd(token:)`. Reaching `.finished`
while foregrounded also retires the now-redundant pending alert (no double buzz). Tests:
`testRestartSynchronouslyRetiresTheAlreadyScheduledAlertById`,
`testFinishingForegroundedRetiresTheRedundantPendingAlert`.
