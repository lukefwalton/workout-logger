# 025 — Forgiving ingestion: cardio, never-fail recovery, and looser joining

Post-launch free-form testing surfaced a cluster of ingestion failures that all
share one root: the parser is (correctly) strict and declines anything
ambiguous, but with no on-device model wired up in most builds, those declines
had nowhere to land — so the user hit dead-ends. The guiding instruction was
blunt: **never fail to ingest; match to the closest thing; let the user fix it
on the confirm card.** Don't overfit to specific strings — fix the pipeline.

## What was failing

- `bike 30 min` → "Cardio isn't logged here yet." Cardio wasn't representable.
- `chinups, 7 ... 3` → recovered a name-only draft with a trailing comma and no
  reps; the two different rep counts were dropped.
- a chin-up with no load showed `unspecified × —` instead of bodyweight.
- `120 lbs leg ext 3 set` → "Couldn't read that one yet" (weight-first order,
  "3 set", abbreviated name).
- `leg curl 8x160x3` → dead-ended on the ambiguous `A×B×C` triple.
- the Progress picker showed `chin ups` **and** `Chin-Up`, `dips` **and**
  `Triceps Dip`: spacing/plural variants were spawning duplicate custom lifts
  instead of joining the canonical.

## The shape of the fix

Kept `DeterministicParser` strict (its decline-on-ambiguity tests are the
contract) and added forgiveness around it, plus a dedicated cardio lane.

1. **Cardio is first-class (schema v3).** A new `cardio_entries` table —
   duration/distance based, **independent of the strength session** so it never
   pollutes e1RM/volume with fake reps. `CardioParser` is never-fail: it reads an
   activity keyword (whole-word, so "swim" ≠ "swimmers"), a duration (`30 min`,
   `1:30:00`, `1h 20min`), and/or a distance (`5k`, `3.1 mi`, `1000m`), matches
   the closest `CardioActivity`, and keeps the user's own words when nothing
   matches. `CardioValidator` *normalizes* rather than rejects.

2. **Forgiving strength recovery.** `ForgivingParser` extracts weight, unit,
   sets, reps, and name in **any order**, tolerates filler, reads per-set rep
   lists (`7,3`, `7 then 3`, `7 of them then 3`), handles weight-first prose and
   the `8×160×3` triple (the off-axis number that's too big to be a count is the
   load), and cleans punctuation off the name. Reps it didn't read stay `0` (the
   unset sentinel) so Save stays disabled — recovery never fabricates.

3. **Bodyweight defaulting.** A load-less, unspecified set on a movement that's
   almost always bodyweight (chin-up, push-up, dip, …) defaults to BW, in both
   the strict-draft and recovery paths.

4. **Looser joining (not hardcoding).** `WorkoutStore.resolveExercise` gained a
   punctuation/plural-insensitive layer: whole strings must agree once
   non-alphanumerics and a trailing plural `s` are stripped, so `chin ups`,
   `chin-ups`, and `chinups` all fold onto `Chin-Up` — but distinct lifts never
   collapse (`bench press` ≠ `incline bench press`). Abbreviations (`leg ext`,
   `dips`→`Triceps Dip`) still fall through to the fuzzy/semantic **proposals**
   the user confirms; auto-joining those at confidence is the next lever, left
   out here to avoid silent wrong merges.

## Doctrine check

The boundary held: the parser still only *proposes*, the confirm card still
confirms, and `WorkoutStore` is still the only writer. Cardio got its own write
path (`saveCardio`) and its own validator, so strength analytics stay honest.
The one philosophy nudge was the loose-key join — it resolves *to an existing
canonical*, never merges two canonicals, and only runs after exact + alias miss.

## Not yet

Cardio isn't in the JSON export/import or the Progress charts or the widget yet
(**done since — see 027**), and confidence-based auto-join for abbreviations is
deferred. All are additive follow-ups on top of the v3 table and the loose-key
layer.
