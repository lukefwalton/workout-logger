# 028 — WorkoutStore decomposition: one type, six files

`WorkoutStore.swift` had grown past 1,600 lines and owned five domains at
once: the exercise registry, supplements, cardio, the session/set write path,
and import/export. Centralizing writes is the whole point of the store, but
one file carrying everything was getting expensive to navigate and reason
about. This change splits the *file*, not the *type*.

## Shape

`WorkoutStore` remains one `final class` on one `SQLiteDB` connection; the
implementation now lives in a slim core plus per-domain extension files:

| File | Owns |
| --- | --- |
| `WorkoutStore.swift` | connection, migration, shared plumbing (`count`, ISO helpers) |
| `WorkoutStore+Sessions.swift` | the one `save`, session lifecycle, History edits, all `workout_sessions`/`sets` writes |
| `WorkoutStore+History.swift` | non-isolated reads: counts, open-session snapshot, `lastTime`, `setHistory`, share prompt |
| `WorkoutStore+Exercises.swift` | registry: seed, resolution stack, add/rename/merge/delete, all `exercises`/`exercise_aliases` writes |
| `WorkoutStore+Supplements.swift` | schema-v2 supplement tracking |
| `WorkoutStore+Cardio.swift` | schema-v3 cardio: `saveCardio`, reads, delete |
| `WorkoutStore+ImportExport.swift` | JSON export + merging import, including the raw import inserts |

Zero call sites changed — the public API is untouched, so every feature model
and every test compiles as before. The move was verified mechanically: the
normalized code-line multiset and the full function-signature set of the old
file equal those of the new files, modulo the access-level changes below.

## Why extensions, not sub-store classes

A real decomposition (an `ExerciseRegistry`, a `SupplementStore`, …
composed behind a façade) was considered and rejected for now:

- **Transactions span domains.** `save` resolves/creates exercises inside its
  own transaction; `importData` writes registry, session, *and* cardio rows in
  one transaction (`SQLiteDB.transaction` does not nest — learnings/027). With
  separate classes those helpers become cross-object internal API anyway, so
  the encapsulation win is smaller than it looks.
- **The façade tax is real.** ~60 forwarding shims to keep the API stable is
  pure surface area for signature drift, with no behavior gain.

One type on one connection keeps the single-open-session and
registry-resolution invariants enforced in exactly one place.

## What the split costs (recorded honestly)

Swift's `private` is file-scoped, so seven members had to widen to
`internal`: `db`, `count`, and five registry helpers the save/import paths
call across files (`resolveOrCreateExercise`, `insertExercise`, `insertAlias`,
`exerciseID(slug:)`, `aliasesByExercise`). "Creating an exercise row only
happens inside the save transaction" is now a store-files convention (called
out in the doc comments) rather than a compiler guarantee. Everything else —
row-level session/set writes, import inserts, resolution internals — stayed
`private` in its domain file, which is most of the original enforcement.

If a future leg wants the compiler guarantee back, the path is extracting the
storage layer into a local Swift package where `internal` stops at the module
boundary — overkill while the app is a single target.
