# 006 — Schema Reset & Exercise Identity (v1.2 PR 2)

The reset gate: collapse to one clean v1 schema and bake in the flat exercise
identity model (§1.1) and the full session schema, so nothing later (history,
progress, health, the widget) is built on a half-schema. Zero installs means we
can do this destructively *now* and never have to migrate it later.

## Flat canonical identity, not a name

The integer rowid is the identity `sets.exercise_id` points at — it never moves.
`slug` (`"close_grip_bench_press"`) is the stable seed/import key; reseeding and
import (PR 13) match on it, so a lift can be re-described without losing history.
`canonical_name` became the *mutable display name* and lost its UNIQUE constraint
— rename/merge (PR 9) can briefly produce duplicate display names, and nothing
logged points at the name anyway.

## Aliases are a table, not a JSON column

Aliases moved from a JSON blob on `exercises` into `exercise_aliases(alias PK ->
exercise_id)`. The primary key *is* the "one alias → one canonical" guarantee:
an ambiguous bare term physically cannot be inserted under two lifts, so it falls
through to fuzzy/LLM clarification (PR 7/8) instead of resolving wrong. Lookups
became a single indexed hit instead of a registry scan, and `ON DELETE CASCADE`
keeps aliases honest when an exercise is merged away.

The subtle trap (caught in review): the store stores/looks up aliases through
`normalizeAlias` (lowercase + whitespace-collapse) and inserts with `OR IGNORE`.
So a *lowercased-only* uniqueness test would miss two seed aliases that differ
only by whitespace — they'd collide at seed time and one would be silently
dropped. The seed-uniqueness test now normalizes with the exact runtime function.

## Families group, they don't collapse

`family_key` (18 families; 21 singletons stay NULL) is for browsing and opt-in
rollups only. PRs and charts compare a canonical to itself. Grouping Romanian
Deadlift near Deadlift for browsing is fine precisely because the family is
non-analytical — the analytics key is the rowid, never the family.

## The write invariant has compiler teeth

Every mutating store API (`save`, `addExercise`, `seedExercisesIfNeeded`,
`migrate`) is `@MainActor`; reads stay non-isolated so the widget's separate
process (PR 12) still compiles. `TodayModel` and `AppDatabase.makeStore` follow.
The store class itself is *not* `@MainActor` — that's deliberate, so reads remain
callable off-main.

## Two reconciliations worth recording

- **`source_text` kept.** The PR-2 `sets` SQL in the spec omitted it, but §2's
  `SetDraft` and the existing export/history path carry provenance, so dropping
  the column would have gutted a working feature. Retained; flagged for review.
- **DB-level CHECKs restored.** The spec's new `sets` literal had relaxed several
  constraints (`set_index >= 1`, nonnegative weight, unit/set_type vocabularies).
  Review rightly flagged that this weakens protection for any future writer, and
  that the comments read stricter than the table. Restored them — adapted for the
  now-nullable `weight`/`unit` (`weight IS NULL OR weight >= 0`, etc.) — so the
  database stays the last line of integrity defense, not just the save path.

## Still pending (can't be done here)

A signed-device smoke test — generate the project, sign, confirm the App Group
container resolves and the store opens, and that the seed loads 89 with slugs and
owned aliases. CI here is Python-only and can't build the iOS target; this is the
one acceptance check that needs a human on a Mac.
