# 009 — Progress: Charts & Honest Analytics (v1.2 PR 5)

Swift Charts over **deterministic, canonical-only** aggregates. The discipline:
no AI touches a number here, and a chart compares an exercise only to itself.

## Canonical-only, never family-collapse

Every series is keyed by `exercise_id`. `family_key` exists for browsing but is
**never** used to aggregate — Bench Press and Incline Bench Press share the
`bench_press` family yet keep entirely separate e1RM/volume series. A test pins
this (`testTwoCanonicalsInSameFamilyStaySeparateSeries`) because a silent family
collapse would corrupt progression the way a wrong muscle tag corrupts volume.

## The aggregates

- **e1RM** per session: max over `.external` sets of Epley `amount·(1+reps/30)`,
  dropping reps > 12 where the estimate is unreliable. One point per session.
- **Volume** per session: Σ `amount·reps` over `.external` sets. One bar.
- **Bodyweight reps trend**: for lifts whose sets are predominantly
  bodyweight/unspecified, max reps per session instead of e1RM/volume — so a
  calisthenics-only user never sees an empty Progress tab.
- **Per-muscle weekly hard sets**: bucket by ISO week, count `policy.isHardSet`
  by **primary** muscle (nil → "Untagged"), stacked bars. `secondary_muscles` is
  stored but deliberately not counted yet (fractional weighting is a later call).

All of this lives in `ProgressAnalytics` as pure functions over
`[WorkoutSetHistoryRow]`, so the math is unit-tested without a UI and stays
honest. The read row gained `primaryMuscle` (appended to the `setHistory` SELECT
as the last column, so no existing column index shifted).

## Honest exclusion, not hiding

`AnalyticsPolicy.countsTowardTrend(feel:isDeload:)` drops off-day and deload
sessions from trend math — a sick day shouldn't read as a regression. One
surfaced toggle (default on) drives both; flipping it off shows everything.
Crucially, excluded sessions **still appear in History** — they're dropped from
*trends*, never hidden.

## Not compiled here

The analytics engine is fully unit-tested (top-set e1RM, volume sums, rep-cap
drop, off-day exclusion both ways, hard-set counting, family separation,
bodyweight reps). The Swift Charts rendering is the part that needs an
Xcode/device pass — it's written against the documented `LineMark`/`BarMark`/
`foregroundStyle(by:)` API but unverified visually here.
