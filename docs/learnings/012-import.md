# 012 — Import: JSON Restore (v1.2 PR 13)

Export already existed; this is the inverse — get your data back after a
reinstall. Import is **propose-then-confirm at the file level**: parse, preview a
summary, then write only on confirmation.

## Match by slug, which is why export now carries it

Exercises are matched on the stable `slug`, not the (mutable) display name or the
old rowid — so a restored "Bench Press" lands on the seeded canonical, and only
genuinely-missing lifts are created as customs (`is_custom = 1`). That required
`ExportedExercise` to finally carry `slug` (+ `family_key` / `is_custom`) — the
deferral flagged back in PR 2/3 review; this is its natural home. The exported
sets reference the *old* exercise rowid, so import builds `oldID → slug → newID`
to re-point them.

## Sessions restore as closed historical records

Each imported session is inserted with `ended_at = exported.ended_at ?? started_at`
— always closed — so a bulk restore can never trip the single-open index
(`idx_one_open_session`). `set_index` is renumbered 1…n per session, and loadless
sets keep their canonical NULL weight/unit (`WorkoutLoad.amount` is already nil for
bodyweight, so the import insert mirrors the fresh-save contract). The CHECKs are
the backstop: a corrupt set (reps > 100, bad load_kind) makes the INSERT throw and
the whole import transaction roll back — "malformed file fails cleanly."

## Idempotent, and dry-run previews

Re-importing the same file double-counts nothing: a session is "already present"
if one with the same `started_at` has the same set count and total reps (a cheap
fingerprint), and is skipped. `dryRun` runs the entire import in a transaction and
then **rolls it back** (via a private sentinel error) while keeping the computed
`ImportSummary`, so Settings can show "Add N workouts · M sets · K new exercises"
before the user commits. Validated the inserts and the fingerprint query in
sqlite3, and the full export→import round-trip in a unit test (every set
reproduced by content).

## Scope

JSON round-trip restore (the app's own export, schema_version 1 and 2) is the
baseline and what shipped. **Merge** is the mode here (add non-duplicate
sessions); a destructive **replace** mode and **CSV (Strong/Hevy) import** are
deliberately deferred (the spec flags CSV as an experimental stretch), to be
slotted later behind their own confirm + review-list.

## Not compiled here

The importer (slug matching, re-pointing, idempotency, dry-run rollback) is
unit-tested via a real export→import round-trip; the SQL was validated in sqlite3.
The SwiftUI `fileImporter` + confirm flow wants a device pass.
