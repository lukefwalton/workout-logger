# 020 — "Last time" on the confirm card

Second ergonomics feature (spec §4). When the pending exercise resolves to a known
canonical, the confirm card shows the most recent finished session's sets for it —
read-only and purely informational, so the next entry has context.

## What shipped

- **`WorkoutStore.lastTime(forExercise:) -> LastTime?`** — a non-isolated read returning
  the sets the exercise was logged with in its most recent **finished** session (in stored
  order), plus that session's `startedAt`. New value types `LastTime` / `LastTimeSet`
  (load + reps) live next to `StoredSet`.
- **`TodayModel.lastTime: LastTime?`** (`@Published`) — populated in
  `refreshPendingExerciseResolution()` only when the name resolves exactly/by alias;
  cleared with the rest of the pending-resolution hints.
- **`TodayView.confirmCard`** — a "Last time" row under the new-exercise notice:
  "135×8, 135×8, 130×6 · 6 days ago", with a `clock.arrow.circlepath` SF Symbol.

## Decisions

- **The open session is excluded.** The query requires `ws.ended_at IS NOT NULL` (on both
  the outer rows and the inner most-recent-session subquery), so "last time" always means
  a genuinely prior workout — never the in-progress one the user is adding to right now.
  This is the subtle correctness point and has a dedicated test.
- **Most-recent finished session that actually contains the lift.** The inner subquery
  picks the latest `ended_at IS NOT NULL` session *joined to a set for this exercise*, so a
  newer finished session that didn't train this lift is skipped (tested) rather than
  yielding an empty hint.
- **Canonical-only** (§1.1) — keyed by `exercise_id`; never blends a different lift's or a
  family's history, exactly like PR detection.
- **Honest framing**: nil when there's no prior finished session (first-ever log) → the row
  simply doesn't render. Nothing is fabricated.
- **Hints move together.** All three confirm-card resolution hints (new-exercise notice,
  fuzzy suggestions, last-time) describe the pending exercise, so I extracted
  `clearPendingResolutionHints()` and call it at every site that resets `pending`. This
  also fixed two pre-existing spots (`clearActivePlan` / `selectPlannedExercise`) that
  reset `pending` but left `pendingSuggestions` stale (latent, since the card was hidden).
- **Cached formatter** (§4 — no per-row allocation): one `static RelativeDateTimeFormatter`
  on `TodayView` for the "N days ago" label, mirroring the cached-formatter rule used in
  History/Progress.

## Validation (not compiled here — Linux container, no Xcode)

- **SQL validated in `sqlite3`** against the `Schema.swift` v1 literal: most-recent finished
  session returned in set order; open session excluded; sessions lacking the exercise
  skipped; two-closed picks the latest; bodyweight rows surface `NULL` weight/unit; the
  plan uses `idx_sets_exercise`. Also confirmed the reused numbered parameter `?1` binds
  once and covers both occurrences.
- **Tests written** (correct-by-inspection, **not run here**):
  `WorkoutStoreTests` (most-recent finished returned, nil on first log, open session not
  counted, skips sessions without the lift), `TodayModelTests` (populates on resolve,
  clears on discard, nil for a first-time lift), `TodayViewFormattingTests`
  (`lastTimeSummary` incl. BW + fractional plates; relative-day phrasing).

## Review notes

`RelativeDateTimeFormatter`'s exact wording is locale-dependent, so the formatting test
asserts the phrase reads as past + mentions days rather than pinning an exact string.

## Review round (surmado) — load-kind honesty

Bundled with this phase's review (and a 🔴 it caught on the Phase-1 detector, fixed in
`019`):

- **🟡 `lastTimeSummary` flattened `.bodyweightPlus` / `.assisted` into a plain
  `weight×reps`**, implying a barbell number the user didn't lift. Now they render
  `BW+25×8` / `asst30×6` (and `.unspecified` stays `—×reps`), so the hint preserves the
  load *kind*. Added `testLastTimeSummaryPreservesLoadKindSemantics`.
- The 🔴 was in `Model/Achievement.swift` `maxRepsPR`, which treated `.unspecified` like
  `.bodyweight` and could surface a rep PR for never-confirmed loads. Fixed there
  (genuine `.bodyweight` only) with detector + store regression tests; see `019`.

## Review round (later) — honest NULL-load reconstruction

🟡: `lastTime(forExercise:)` coerced nullable DB columns into concrete values
(`stmt.double(0)`, `?? .lb`, `?? .external`), so a historical bodyweight/unspecified row
would misstate as a real "0 lb / external" set — undercutting honest-or-nothing. Now it
mirrors `priorSetFacts`: reads `optionalDouble`/optional unit and builds the `WorkoutLoad`
from the *stored* kind, so a loadless row round-trips as itself ("BW"). Validated in
sqlite3; added `testLastTimeReconstructsBodyweightLoadHonestly`.
