# 019 — PR detection (`SaveResult.achievements`)

First of the deferred ergonomics pass (spec §4). When a set is saved, the store now
detects a personal record and surfaces it as a tasteful notice on Today — honest data,
computed from logged sets, never guessed.

## What shipped

- **`Model/Achievement.swift`** — three pure pieces, no DB/UI/AI:
  - `OneRepMax` — the Epley formula (`weight × (1 + reps/30)`) and the rep cap (12) in
    **one** place. `ProgressAnalytics` now calls it instead of re-deriving the formula
    inline, so the charts (PR 5) and PR detection agree by construction.
  - `Achievement` (+ `AchievementKind`) — a transient value with an honest `headline`
    string. Three kinds: `.estimatedOneRepMax`, `.weightForReps`, `.maxReps`.
  - `AchievementDetector` — pure detection over a minimal `SetFact` projection.
- **`SaveResult.achievements: [Achievement]`** — defaulted to `[]` in a hand-written
  initializer so every existing `SaveResult(sessionID:setIDs:)` call site is undisturbed.
- **`WorkoutStore.save(_:into:)`** computes achievements **inside the save transaction**:
  resolve every set's exercise first, snapshot each exercise's prior history via the new
  private `priorSetFacts(exerciseID:)` **before** the new sets are inserted, then detect.
- **Today** surfaces it: `TodayModel.lastAchievements` (published, cleared when a new
  entry begins, set from the save result) → `TodayView` renders one `trophy.fill` card
  per PR under "Saved N sets" (SF Symbol, never emoji — `SessionFeel` precedent).

## Decisions

- **One headline PR per exercise**, prioritized e1RM → weight-for-reps (loaded) → max
  reps (bodyweight). Keeps the notice tasteful and matches the spec's single-line
  example; the three kinds still each "win" for the lift they fit. Bodyweight lifts get a
  rep PR moment via `.maxReps`.
- **Honest-or-nothing** (doctrine: a PR is a *fact*, not a guess):
  - First time a lift is logged → not a PR (no prior history to beat).
  - Ties are not PRs (strict `>` with a float epsilon).
  - Unspecified / zero-weight sets never produce a weight PR.
  - `weightForReps` requires a prior set **at the same rep count** to beat.
  - `bodyweightPlus` / `assisted` earn no PR at launch — a deliberate gap, not a
    fabricated cross-load comparison.
- **Canonical-only** (§1.1): comparison is the exercise's own `exercise_id` history —
  never a `family_key` rollup, which would corrupt per-canonical PRs.
- **A notice, not a stored fact** (§4): achievements are recomputed each save and live in
  `SaveResult` / a published view-model property; nothing is persisted. (`updateSet`'s
  existing comment already noted edits don't recompute PRs — unchanged.)
- **Reuse, not re-derivation**: the Epley formula and rep cap are single-sourced in
  `OneRepMax`; `ProgressAnalytics.e1rmRepCap == OneRepMax.repCap`.

## Validation (not compiled here — Linux container, no Xcode)

- **Algorithm prototyped in Python** first; all honest-or-nothing edge cases pass (first
  ever, beater, worse, tie, equal e1RM at a different rep scheme, unspecified/zero-weight,
  bodyweight rep PR/tie/first-ever, weight-for-reps headline incl. above the e1RM cap).
  The Swift `AchievementDetector` mirrors that prototype.
- **`priorSetFacts` SQL validated in `sqlite3`** against the `Schema.swift` v1+v2 literal:
  correct shape, loadless rows surface `NULL` weight/unit as `nil`, and the query uses
  `idx_sets_exercise` (`EXPLAIN QUERY PLAN`).
- **Tests written** (correct-by-inspection, **not run here**):
  `AchievementDetectorTests` (pure edge cases + headlines + formula), `WorkoutStoreTests`
  (first-ever→none, beater→e1RM, worse→none, bodyweight→max-reps),
  `TodayModelTests.testSaveSurfacesPersonalRecordNotice`.

## Wiring note

The widget target compiles only `WorkoutWidget/`, `WorkoutChatLog/Shared/`, and
`SQLiteDB.swift` — **not** `WorkoutStore.swift` (it reads via `WorkoutWidgetReader`). So
`SaveResult`/`Achievement` are app-target only; `Model/Achievement.swift` needs no
`project.yml` change (the app target globs `WorkoutChatLog/Model`). Earlier concern that
the widget compiles the write path was wrong — verified against `project.yml`.

## Review round 1 (surmado) — mixed units

The bot caught a real honesty bug (🔴): `estimatedOneRepMaxPR` / `weightForRepsPR`
compared raw `weight` numbers without partitioning by `unit`, so a user with mixed lb/kg
history could see a **false** PR (e.g. 150 lb logged after 100 kg). Fix matches the app's
**never-silently-convert** doctrine (`WeightUnit`) and the existing `WorkoutShareSummary`
precedent (suppress across mixed units rather than convert): both comparisons now run
**within a unit** — prior history in a different unit is ignored, not converted. A lift
that legitimately accumulates both units simply gets PRs per unit. Added regression tests
(`AchievementDetectorTests` mixed-unit cases + `WorkoutStoreTests.testMixedUnitHistory…`)
and re-validated in Python. (`ProgressAnalytics.e1RMSeries` has the same latent mixed-unit
behavior, pre-existing and out of this PR's scope — noted for a later pass.)

## Review round 2 (surmado) — headline determinism + the one-load invariant

All-yellow, no red. Two recurring observations resolved in code rather than just
justified:

- **`weightForReps` headline selection** used to pick the winner by raw weight, which is
  meaningless across units. Now it ranks qualifying beaters by **improvement over their
  own-unit prior**, with a deterministic tie-break (improvement → reps → weight → unit).
  A mixed-unit entry now yields a stable, unit-safe headline (a kg set that beats its own
  history by more can headline over a numerically larger lb set). Validated in Python.
- **The "any external set ⇒ loaded path" routing** assumes one load style per exercise per
  entry. Confirmed that invariant on the only caller (the parser emits one load per entry;
  `TodayModel.setWeight` forces a uniform `loadKind`), documented it on `achievement(...)`,
  and added `testExternalSetTakesLoadedPRPathNotMaxReps` to lock the precedence. Worst case
  if a future writer breaks it is a loaded PR shown instead of a rep PR — never a fabricated
  one.

The remaining yellow ("run the XCTests on macOS/Xcode before merge") is inherent to this
Linux environment and already stated honestly in the PR; it's a human-on-device step.
