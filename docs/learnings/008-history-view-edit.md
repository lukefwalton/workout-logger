# 008 — History: View, Delete, Edit (v1.2 PR 4)

The first surface that *reads* the real multi-set sessions PR 3 creates — a
session-grouped, set-by-set audit, with delete and edit for both sets and
sessions. Trust-restoring: it shows exactly what was saved, and lets you fix it.

## Grouping rides on the query's order

`setHistory` already returns rows ordered `started_at DESC, ws.id DESC, set_index
ASC`, so one session's rows are contiguous and in set order. `HistoryModel.group`
just walks the rows and starts a new `Section` whenever the session id changes —
no dictionary, no re-sort, stable and O(n). The model is a plain testable state
machine (`loading / loaded / empty / failed`); the view is thin over it.

## Cached formatters (§4)

History scrolls, so the ISO8601 parser and the display `DateFormatter` are
`static let` on the model, not per-row allocations. Section titles use the
session name when set, else the formatted start date.

## Edits go through the store, and can be rejected

Four new `@MainActor`, transaction-wrapped store APIs:

- `deleteSet` is scoped to the set's own session — it removes the row and then
  deletes the session *only if it's now empty*, so a multi-set workout is left
  intact while deleting its last set cleans up the empty shell.
- `deleteSession` relies on the FK `ON DELETE CASCADE` for its sets.
- `updateSet` reuses the save-path `WorkoutValidator` (shaped as a one-set draft)
  and re-resolves the exercise name through the registry (exact→alias→create),
  so an edit behaves exactly like a fresh save. v1 simplification, noted in code:
  editing does **not** recompute PR/achievement detection.
- `updateSession` post-fills name/times/feel/deload/notes. `started_at`/`ended_at`
  are COALESCEd (a nil keeps the stored value — `started_at` is NOT NULL), and it
  rejects `ended_at < started_at` with `WorkoutStoreError.endBeforeStart`.

The editors return an error *message* (nil on success) rather than throwing into
the view, so a rejected edit keeps the sheet open with the reason shown and the
data untouched — the model only reloads on success.

## Not compiled here

The store/model logic is unit-tested (grouping/sort, delete scoping, update
validation + re-resolution, end-before-start rejection). The two editor sheets
and the swipe/menu affordances are the least machine-checkable part and want an
Xcode/device pass.
