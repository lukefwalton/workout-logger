# 029 — Diligence fixes: honest AI copy, real connection serialization, loud CI

Four fixes from an external review, ordered by risk.

## "No AI in this app" was false

Settings claimed "No AI in this app" while the README and the code ship an
optional Foundation Models parser. Even with nothing leaving the device,
copy that contradicts the product is the kind of thing that looks deliberate
in diligence. The copy is now "**No cloud AI**… the optional entry parser
uses Apple's on-device model — your entries are never sent to us," and
`docs/privacy.md` gained an "On-device text parsing" section stating the
processing, its confirm-before-save boundary, and the absence of any cloud
fallback. Doctrine recorded in `.github/STANDARDS.md`: privacy claims must
describe the same product everywhere.

## FULLMUTEX was doing less than the comments said

`SQLITE_OPEN_FULLMUTEX` makes each C call thread-safe; it does **not** make a
Swift `transaction` closure atomic. On one shared connection, a detached read
could land between BEGIN and COMMIT and see half a workout — and
`HistoryModel.load` ran three separate reads (rows, spans, cardio) that a
mid-load commit could set against each other.

The fix keeps one connection (the reviewer's other option, split read/write
connections, buys read/write overlap at the cost of two-connection lifecycle
and WAL-visibility subtleties — not worth it at this app's write rates):

- `SQLiteDB` gains a **recursive connection lock**; `transaction` and
  `readTransaction` closures are serialized whole.
- `readTransaction` is now **nesting-aware** (`sqlite3_get_autocommit`): a
  wrapped read called inside an open transaction joins it instead of issuing
  a nested BEGIN, which SQLite rejects. Recursion in the lock matters for the
  same reason (`resolveExercise` runs inside `save`).
- **Every `WorkoutStore` public read** is wrapped in `readTransaction`, so no
  bare statement can interleave into a write; multi-read consumers
  (`HistoryModel.load`, `dataExport`) get `store.snapshot` — one deferred
  transaction around all their reads. CPU work (grouping, calorie math)
  stays outside the snapshot so the lock is never held for math.

Pinned by two new `SQLiteDBTests`: nested read-inside-write, and a
writer/reader hammer asserting a reader can never observe an odd row count
from two-inserts-per-transaction — the exact interleaving FULLMUTEX permits
and the lock forbids.

## `#if canImport(FoundationModels)` could vanish from CI silently

The unit-test job runs on unpinned `macos-14`, where `canImport` is false —
green CI proved only the deterministic fallback compiled. `ios-tests.yml`
gains a `foundation-models-guard` job (macos-26) whose first step type-checks
a probe that `#error`s if the module is missing. That ordering is the point:
without the probe, even the pinned job would fall back silently if the
runner's toolchain drifted; with it, absence fails loudly, and the subsequent
full build genuinely compiles the FM branch (catching symbol drift).

## Restore copy could contradict its own preview

The import preview counted `addedExercises`; the completion message didn't,
so an exercise-only restore ended with "Nothing new to restore" after
changing the library. Both messages now compose from one
`ImportSummary.addedParts` list (plus `skippedCount`), so the surfaces cannot
drift — the class of bug is gone, not just the instance. Locked by
`WorkoutExportModelsTests`.
