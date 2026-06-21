# 015 — Calorie estimate (session-bounds precedence) (v1.2 PR 11)

A deliberately-rough per-session kcal estimate: `kcal ≈ MET × bodyweight_kg ×
duration_hours`. Deterministic, **AI never touches it**, and honest — missing inputs
prompt, never fabricate. Fully buildable here (the pure logic + the manual-bodyweight
path); only the HealthKit bodyweight source belongs to PR 10.

## Duration precedence, with honest clamps

The whole subtlety is *which* duration to trust, in order: explicit `ended_at −
started_at` (set at finish or by editing the session end time, PR 4) → the set-time
span (`MAX − MIN` of the sets' `created_at`) → a manual duration → else a "add a
duration" prompt. Implemented as a pure `CalorieEstimate.resolveDuration` returning
the hours *and* its source, so tests pin exactly which tier fired. Degenerate cases
are clamped, never invented: a single-set session (zero span) gets a small fixed
fallback (10 min) rather than 0; an absurd gap (session left open between sets) is
capped at `maxSessionHours` (6). All three knobs live in a typed `CaloriePolicy`
(MET 5.0, cap, fallback) — the spec's "AnalyticsPolicy-style knob," not magic numbers.

In practice every real session has ≥1 set, so the set-span tier almost always yields
*some* duration — `needsDuration` is essentially an edge (no usable timestamps), and
the common outcomes are a real kcal number or `needsBodyweight`. I validated the
precedence and the formula in Python before porting (`600 kcal` for 80 kg × 1.5 h, the
single-set fallback, the cap).

## The set-span read, not a fattened history row

`WorkoutSetHistoryRow` carries no per-set `created_at`, and I didn't want to bloat
that widely-used type for one feature. Instead a focused, non-isolated
`WorkoutStore.sessionSetSpans()` does one grouped `MIN/MAX(created_at)` query keyed by
session. Because `created_at` is the store's fixed ISO8601, lexical MIN/MAX equals
chronological — validated against the schema. `HistoryModel.load` batches that read
once and attaches a `CalorieEstimate.Outcome` to each section; the History header
renders "~X kcal (estimate)" or a gentle bodyweight prompt (never a zero/fake).

## Bodyweight: shared key with PR 10, dedupe at merge

Bodyweight is the one input that crosses PRs. PR 10 (Apple Health, separate branch)
introduces the manual bodyweight Settings field and the HealthKit read; PR 11 only
*consumes* a kg value. To avoid divergent data, `CaloriePreferences.bodyweightKgKey`
is the **same string** as PR 10's `HealthPreferences.manualBodyweightKgKey`, so the
manual bodyweight is one value wherever it's entered. This PR adds its own "Calorie
estimate" Settings field (so the feature is usable standalone, per the spec's "fully
doable here"); when PR 10 also lands, the two fields point at the same key — **dedupe
the duplicate Settings row at merge** (data already agrees). The HealthKit bodyweight
read wires in then too, via PR 10's `HealthWorkoutCoordinator.bodyweightKilograms()`.

## Testability over timing

The pure estimator is exhaustively unit-tested (every precedence tier, the formula,
clamps, both prompts, zero-bodyweight-as-missing). The `HistoryModel` integration test
is deliberately **timing-independent**: it asserts the *kind* of outcome (kcal vs.
`needsBodyweight`) rather than an exact number that would depend on sub-second set
timestamps in a fast test — bodyweight is injected, so the wiring is what's verified.

Not compiled here (Linux/no Xcode): SQL validated in sqlite3, the algorithm in Python,
the logic unit-tested; the History header line is correct-by-inspection (device pass).

---

*This PR is combined with the daily-supplement-tracking feature (see
`feature-supplement-tracking.md`) at the user's request — one PR carries both.*

## Review round

The bot flagged two real issues, both fixed:

- **🔴 Supplement store failures were invisible.** With this PR introducing the first
  schema migration, the `try?`-to-empty reads and DEBUG-only write catches meant a
  migration/SQLite failure would read as "no supplements" or a dead tap. Now
  `SupplementModel` keeps a `storeError` (and `SupplementTrendsModel` a `loadFailed`),
  preserves the last-shown data on failure rather than blanking it, and the Today card
  + Progress section render a real error line — matching how the workout screens fail.
- **🟡 `Date()` fallback masked bad timestamps.** `attachCalorieEstimates` substituted
  `Date()` for an unparseable `startedAt`, which would invent an explicit-bounds
  duration and make the "deterministic" estimate non-deterministic. `startedAt` is now
  `Date?` through `CalorieEstimate`; a missing start simply disqualifies the
  explicit-bounds tier (set-span still applies), and nothing is fabricated.

A second round caught the subtler edges of the first round's fix:

- **Shared error state could self-clear.** `reloadList()` and `reloadToday()` each
  cleared `storeError` on success, so if the list read failed but the intake read
  succeeded, the second wiped the first's error. Fixed by clearing `storeError` exactly
  once at the *start* of each operation; the individual reads now only ever *set* it.
  (Also fixed a latent `log(...)` call left dangling when that helper became `fail`.)
- **Set-span query failure was swallowed.** `HistoryModel` degraded a
  `sessionSetSpans()` failure to `.needsDuration`, indistinguishable from genuinely
  missing duration. Now it's caught and logged (DEBUG) so a read failure stays
  diagnosable, while the estimate still degrades gracefully (the main history read
  keeps its own failure state).

On the bot's question about `SupplementTrendsView` refreshing on tab-switch: it uses
`.task { model.load() }` + `.refreshable`, the **same** pattern as the workout charts
(`ProgressModel`), so its refresh behavior is consistent with the rest of Progress —
a device-check item, not a new divergence.
