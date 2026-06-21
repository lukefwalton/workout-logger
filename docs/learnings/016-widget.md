# 016 — Home Screen widget (current / last workout) (v1.2 PR 12)

A read-only WidgetKit widget on the shared App Group store: the current open
workout's set count while one is active, otherwise the last finished workout. This is
the PR the whole "reads are non-isolated" design existed for — and it's mostly Xcode
target-wiring, so the bulk is correct-by-inspection + a device pass.

## Why store reads being non-isolated finally pays off

The widget runs in a **separate process** and opens its **own** connection to the
same SQLite file in the App Group container (cross-process WAL reads are safe — the
store already runs in WAL). It must compile without the `@MainActor` write path, so
this PR carves out a **Shared** module compiled into both targets:

- `SharedDatabase` — `AppGroup.identifier` + `databaseURL()` + an ISO8601 date
  parser, extracted from `AppDatabase` (whose `makeStore()` stays app-only because it
  pulls in `WorkoutStore`/`ExerciseSeed`).
- `WidgetWorkoutSnapshot` — a tiny DTO (`.current` / `.last` / `.empty`) so the widget
  never sees `OpenSession`, `WorkoutSetHistoryRow`, etc.
- `WorkoutWidgetReader` — opens its own `SQLiteDB` and runs **only SELECTs** to build
  the snapshot. Open session wins; else most-recent finished; else empty; any read
  failure degrades to `.empty` (never crashes the widget).

The widget target lists exactly these Shared files plus `SQLiteDB.swift` — not the
whole Storage folder — so it stays minimal and never links the write path.

## Validated the reads, kept the logic testable

The two queries (open-session set count; most-recent finished session) were validated
in sqlite3 against the schema (empty → none; finished-only → last; open present → open
wins; newest-of-two). `WorkoutWidgetReader.snapshot(db:)` takes a `SQLiteDB` so the
selection logic is unit-tested against a real seeded store — the same SQL the widget
runs on device (there via a separate cross-process connection).

## Freshness + the quick-log deep link

The widget refreshes on a modest hourly backstop **and** the app calls
`WidgetCenter.reloadAllTimelines()` after each save/finish (a `WidgetRefresher` helper
gated by `#if canImport(WidgetKit)`, so the app still builds where WidgetKit is
absent; a no-op with no widget installed). Tapping the widget opens the app on Today
via a `workoutchatlog://today` deep link: the widget sets `.widgetURL`, the app
registers the URL scheme and handles `.onOpenURL`, and `RootTabView`'s selected tab
became an app-owned `@Binding` so an external link can select it.

## Not compiled here

No WidgetKit/Xcode on Linux, so the widget target, its SwiftUI views, the timeline
provider, and the App Group container behavior are **correct-by-inspection** — the
real render, the cross-process read, and the deep link are a human-on-device
acceptance step. The shareable read logic (queries, snapshot selection, DTO) is
unit-tested and sqlite3-validated. WidgetKit symbols (`StaticConfiguration`,
`TimelineProvider`, `containerBackground`, `WidgetBundle`) follow the current SDK but
should be confirmed in Xcode.

## Device acceptance checklist (the on-device pass this PR needs)

- [ ] `xcodegen generate` succeeds with the new `WorkoutWidgetExtension` target; the
  app builds and signs with both targets carrying the App Group entitlement.
- [ ] Add the widget to the Home Screen; it renders small + medium.
- [ ] Empty state before any log; "Current workout · N sets" while a session is open;
  "Last workout" after finishing.
- [ ] It updates shortly after a save and after a finish (the `reloadAllTimelines()`
  nudge).
- [ ] Tapping the widget opens the app on the **Today** tab (the
  `workoutchatlog://today` deep link), from both cold launch and warm resume.
- [ ] Force a misconfig (e.g. wrong App Group) and confirm the `os.Logger` "Widget"
  category surfaces the failure in Console while the widget still shows empty.

## Review round

The bot flagged the failure-visibility gap (consistent with the rest of this leg):
`WorkoutWidgetReader` collapsed App Group / DB-open / query failures all to `.empty`
with no signal. Kept the `.empty` behavior but added `os.Logger` diagnostics around
container resolution, DB open, and the query catch — release-safe, since a widget
can't easily be debug-attached. Also removed the `Date()` fallback in
`lastFinishedSession`: if `ended_at` can't be parsed it returns nil rather than a
misleading "last workout = now." (On the bot's question: `SharedDatabase.isoFormatter`
matches `WorkoutStore`'s exactly — `[.withInternetDateTime]` — so drift isn't expected;
the guard is defensive.)

A later pass added the `String(describing:)` logging fix (the error types are
`CustomStringConvertible`, not `LocalizedError`, so `localizedDescription` dropped
their detail), a log on the `ended_at` parse-failure branch, and a unit test that
inserts a malformed `ended_at` row and asserts the reader degrades to `.empty`.

On the "does `SQLiteDB(path:)` open read-only?" question: **no — it's the standard
read/write+create initializer, by design.** The spec's guidance is "cross-process WAL
reads are safe — already set," and the "never writes" guarantee is enforced by the
reader issuing **SELECTs only**, not by open flags. A `SQLITE_OPEN_READONLY` open over
a WAL database has device-specific `-shm`/`-wal` caveats (it can fail to open when it
can't create the shared-memory file) that **can't be validated in this Linux
environment**, so hardening to read-only flags is deferred to the on-device pass rather
than guessed at here. Confirm the open mode + the rapid-successive-save refresh
behavior (WidgetKit can throttle `reloadAllTimelines()`) during device QA.
