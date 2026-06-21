# 011 — Rename / Merge Exercises (v1.2 PR 9)

Unknown-exercise creation (PR 7 declines a fuzzy suggestion → new custom canonical)
inevitably produces duplicates: "Lat Pulldown", "Lat Pull Down", "Pulldown
Machine". Duplicate canonicals fragment progress charts (each is its own series),
so Settings → Exercises lets users fix them — rename, merge, or delete.

## Rename is display-only

`renameExercise` changes `canonical_name` and nothing else: `id` and `slug` are
untouched, so every logged set keeps pointing at the same identity and history is
unaffected. Renaming onto another exercise's display name is rejected with
`renameCollision` (a merge was almost certainly meant) — display names aren't
UNIQUE in the schema, but a silent duplicate is bad UX, so the store guards it.

## Merge is one transaction, validated in SQLite

`mergeExercise(from:into:)`:
1. `UPDATE sets SET exercise_id = target WHERE exercise_id = source` — re-point all sets.
2. `UPDATE exercise_aliases SET exercise_id = target WHERE exercise_id = source` —
   fold the source's aliases. No collision is possible here: `alias` is the PK and
   is unchanged, and source/target can never share an alias string.
3. `INSERT OR IGNORE` the source's old name as an alias of target — so future logs
   of the old name resolve to the merged lift. OR IGNORE is where "keep the
   existing owner on collision" lives.
4. `DELETE` the source row (its aliases/sets are already re-pointed, so nothing
   cascades away).

The target ends up owning the combined history, so charts stay intact. I ran the
exact four-statement sequence through sqlite3 to confirm: source gone, all sets
and aliases land on the target. Self-merge is rejected (`selfMerge`).

Merge is for **duplicates, not variations**. The store can't know intent, so the
picker's copy is explicit ("a Close-Grip Push-Up is not a Push-Up"), and shared
`family_key` is surfaced only as a *weak hint*, never a gate.

## Delete is narrow on purpose

`deleteExercise` removes a lift only when it's user-created **and** unused
(`is_custom = 1`, zero sets) — never orphan logged data, and never delete a seeded
lift (`cannotDeleteSeeded` / `exerciseInUse` otherwise). For anything with history,
the answer is merge, not delete.

## UI

`ExerciseLibraryView`: searchable, grouped by `family_key` (singletons under
"Other"), each row showing usage count + a custom badge, with a per-exercise menu
(Rename / Merge into… / Delete-when-unused). The merge target is chosen from a
searchable picker with the duplicates-not-variations warning and a destructive
confirmation.

## Not compiled here

Store logic is unit-tested (re-point + delete in one transaction, alias fold,
rename preserves id/slug + set associations, rename-collision / self-merge
rejection, delete gating) and the merge SQL was validated in sqlite3. The
SwiftUI library/picker wants a device pass.
