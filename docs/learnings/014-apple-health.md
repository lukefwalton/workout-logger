# 014 — Apple Health (optional, opt-in) (v1.2 PR 10)

Optional, opt-in HealthKit: read bodyweight, write **one** strength workout per
*finished session* — on-device, never transmitted, fully functional when denied.
Built behind a protocol with a fake-driven test suite; the real HealthKit code is
gated and correct-by-inspection (verify symbols in Xcode).

## Two gates, deliberately separated

The spec's sharpest point: **system write permission is not the same as user
intent.** So there are two independent gates, and both must be true before anything
is written:

- **Intent** — a Settings toggle "Save workouts to Apple Health", default **off**,
  stored in `HealthPreferences.saveWorkoutsToHealthKey`.
- **Capability** — HealthKit available on the device *and* sharing authorized.

`HealthWorkoutCoordinator` owns the intent gate (reads the toggle from injectable
`UserDefaults`) and delegates the capability gate to the `HealthService`. That split
is exactly what the tests pin: toggle off → zero writes even with permission; toggle
on + denied → zero; toggle on + authorized → exactly one.

## Protocol isolation, same pattern as Foundation Models

`HealthService` is Foundation-only; the real `HealthKitService` lives entirely inside
`#if canImport(HealthKit)`, and `HealthServiceFactory.make()` is the one place the
two worlds meet. So no HealthKit symbol reaches always-compiled code — which matters
for the widget process (PR 12) and the Linux CI, and lets the tests drive a
`FakeHealthService` with no import. Bodyweight is carried in **kilograms** across the
protocol boundary (HealthKit's native unit and what the PR 11 formula wants).

## One workout per session, never the calorie guess

The write fires from `TodayModel.finishWorkout` — once, on finish, not per set. It
captures the session's real `started_at` *before* closing (via `currentOpenSession()`),
uses `Date()` as the end, and only writes when it has sensible bounds (`end > start`).
Crucially it writes **no** energy/distance samples: the rough calorie estimate stays
in-app and never pollutes the Move ring, which is the precise thing App Review bounces.
The write is best-effort and non-blocking (a detached `Task`), so a slow HealthKit
call never stalls the finish sheet; the `Task` handle is exposed only so tests can
await it deterministically.

## Bodyweight: HealthKit, else manual, else honest blank

`bodyweightKilograms()` returns HealthKit's latest sample if available, else the
manual Settings value, else `nil` — never a fabricated number. PR 11 consumes this
and shows "add your bodyweight" on `nil`. The manual field is stored in kg (a `kg`
label in Settings); refining the unit display is left to PR 11, which owns the
calorie UX.

## A date-precision gotcha I checked before trusting the test

The store serializes timestamps with `ISO8601DateFormatter([.withInternetDateTime])`
— **whole seconds, no fractional part**. The finished-session write compares the
DB-read start against a live `Date()` end. Because the stored start is truncated
*down* to its second, it stays ≤ the real save time < the finish time, so `end >
start` holds even in a sub-millisecond test. (A degenerate `end <= start` is still
guarded and tested separately.) Worth confirming rather than assuming.

## Setup wired, device step flagged

`project.yml` gains the `com.apple.developer.healthkit` entitlement and the new
`WorkoutChatLog/Health` source path; `Info.plist` gains
`NSHealthShareUsageDescription` / `NSHealthUpdateUsageDescription`; the README
entitlements line now states opt-in HealthKit (per spec §4). The symbol names in
`HealthKitService` (`HKQuantityType(.bodyMass)`, `HKWorkoutBuilder`,
`.traditionalStrengthTraining`, the authorization/finish APIs) are from the spec and
**must be verified in Xcode** — not compiled here. The real acceptance (a signed
build writing one strength workout visible in Fitness, no estimated energy) is a
human-on-device step.

## Review round

No red flags; two yellows, both fixed:

- **The toggle could read "on" while the feature couldn't run.** Now enabling it
  requests authorization and reverts to off (with a note) unless workout sharing is
  actually authorized. I first justified leaving the toggle on after a denial by
  claiming HealthKit hides write-denials — **that was wrong**, and the reviewer
  rightly called it. HealthKit hides *read* status, but **share** status is queryable
  (`authorizationStatus(for: .workoutType()) == .sharingAuthorized`) — which
  `saveStrengthWorkout` already relied on. So `requestAuthorization()` now returns
  that share status after the prompt, and the existing revert logic correctly handles
  an explicit workout-sharing denial, not just unavailability/errors.
- **Production failures were DEBUG-only `print`s.** The gated service now logs
  auth/write failures through `os.Logger` at `.error`, visible in the unified log on
  a device (an `HKError` carries no health values, so the description is logged
  `.public`).

On the bot's question about Apple-platform CI for the gated file: there isn't one —
the repo CI is Python-only by design, so Xcode/device is the long-term guardrail for
every gated path (same as FoundationModels in PR 8). The fake-service tests cover the
coordinator's gating logic; SDK/API drift in `HealthKitService.swift` is caught on the
first real build.
