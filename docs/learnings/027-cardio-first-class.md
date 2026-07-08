# 027 — Cardio everywhere: export/import, Progress, widget

Closes the "Not yet" list from 025: cardio landed in schema v3 with its own
ingestion lane but had zero presence in the JSON export/import, the Progress
charts, or the widget. This leg is purely additive — no migration (v3 already
exists), no parser or History changes — and threads one doctrine through three
very different surfaces: **cardio is real data, so it round-trips, trends, and
surfaces — but it never mixes into strength numbers, never fabricates a metric,
and never converts a unit.**

## Export format goes to schema_version 3

`WorkoutDataExport` gains a top-level `cardio` array (`ExportedCardioEntry`
mirrors the table; `distance_unit` is typed so a corrupted unit fails decode
loudly, like `WorkoutLoad`'s unit). The version bump is honest labeling, not a
gate: decode stays version-blind, and the only special line is a
`decodeIfPresent … ?? []` so every v1/v2 file still imports. The frozen
top-level-keys test was updated *in the same commit* as the DTO — that test
exists precisely to make format changes loud. The key is always **encoded**
(empty array when no cardio) so the wire contract stays an exact set rather
than a conditional one.

**Forward compat is knowingly lossy:** the shipped v1.1 importer ignores
unknown JSON keys, so a v3 file imported there drops cardio silently. Nothing
can fix that retroactively; acceptable for a personal-backup format, recorded
here.

## Import: the nested-transaction trap, and count-based idempotency

Two things the obvious implementation gets wrong:

1. **Never call `saveCardio` from import.** `SQLiteDB.transaction` is plain
   BEGIN/COMMIT — it does not nest, and import already runs in one transaction.
   Cardio inserts go through a raw private `insertImportedCardio` (the
   `insertImportedSet` pattern), with `CardioValidator.normalized` applied
   first so the fresh-save contract still holds; the schema CHECKs remain the
   rollback backstop for a hand-mangled file.
2. **A plain EXISTS fingerprint would collapse genuine duplicates.** Two
   identical bouts ("ran 10 min" twice, logged the same second) are two facts
   and must round-trip as two rows. Idempotency is therefore *count-based*: per
   normalized fingerprint (`logged_at`, activity, duration, distance, unit —
   compared with `IS ?` so NULLs match), the pre-existing DB count is
   snapshotted once, and only file occurrences beyond it insert. Fresh import
   adds N of N; re-import adds 0. (The session fingerprint has the same latent
   collapse flaw — left untouched, out of scope.) Validated in sqlite3 via a
   Python simulation of the exact loop, plus unit tests.

The cardio loop sits **before** the dry-run sentinel, so the Settings preview
counts cardio and still rolls back.

## Progress: a third self-contained section, honest about what it can't say

`CardioTrendsView`/`CardioTrendsModel`/`CardioAnalytics` clone the supplement
section's shape (pure analytics enum, self-contained card, `.task` +
tab-change reload, keep-last-shown on read failure) — cardio renders even for a
user who never lifts. The headline chart is **weekly minutes** stacked by
activity (ISO-week buckets, same calendar convention as the muscle chart)
because minutes are unit-free. The honesty rules:

- A bout without a duration contributes **zero fabricated minutes** — it's
  excluded from the chart, and if *all* bouts are distance-only the card says
  "Add durations to see weekly minutes" instead of rendering an empty chart.
- Distances are summed **per logged unit** and displayed side by side
  ("12 mi · 5 km") — the never-silently-convert rule from `CardioDistanceUnit`
  extends to aggregates.
- Grouping is by the stored activity string **verbatim**. Parser-matched bouts
  store canonical displays so this groups well in practice; free-text stays its
  own series. No fuzzy merging in numbers.

## Widget: raw fields over preformatted strings, newest-fact precedence

`WidgetWorkoutSnapshot` gains `.lastCardio(activity:durationSeconds:distance:
distanceUnit:loggedAt:)` — raw fields, not a baked string, with
`CardioActivity`/`CardioDistanceUnit`/`CardioFormat` **moved to Shared**
(CardioDisplay.swift, dual-membership like `WorkoutDateFormat`) so the widget
renders through the same formatter as History and the icon *derives* from
`CardioActivity.icon` by display name — no hand-copied map to drift. (A first
draft duplicated the icon switch behind "the widget can't see CardioActivity,"
but that boundary was self-imposed file placement: the enum is Foundation-only,
so moving it was strictly better than a map + drift-guard test.) Free-text
activities honestly fall back to the generic heart; keyword matching stays in
the parser.

Reader precedence: an open strength session always wins; otherwise the *newer*
of last-finished-workout vs last-cardio (tie → strength, the established
surface). The two candidates come back as `(snapshot, when)` tuples so the
comparison never destructures enum payloads back apart. Unparseable `logged_at`
logs and drops the cardio candidate — same no-`Date()`-fabrication doctrine as
`ended_at` — which deliberately means a malformed strength `ended_at` now
degrades to a valid cardio bout instead of straight to `.empty` (pinned by
`testMalformedEndedAtFallsBackToCardio`).

## Review round

An eight-angle review pass (line scan, removed-behavior audit, cross-file
trace, reuse/simplification/efficiency, altitude) before the commit caught,
and this leg fixed:

- **The upgrade blank (the one real ship-blocker).** The widget never runs
  migrations, and WidgetKit can refresh it after the app *update installs* but
  before the app's first launch stamps schema v3 — so an unconditional
  `SELECT … FROM cardio_entries` threw "no such table," escaped the read
  transaction, and blanked every upgrading user's widget to `.empty`, hiding
  their real last workout. The cardio candidate read is now non-throwing: any
  cardio-side failure logs and degrades to "no cardio candidate" while the
  strength path still renders. Lesson: **a widget query against a table only
  the app creates must degrade per-candidate, never per-snapshot.**
- **Aggregated floats lie in print.** `String(1.1 + 2.2)` renders
  "3.3000000000000003"; verbatim single values keep `CardioFormat`'s raw
  formatting (that's the point), but *summed* distances round to one decimal.
- **Widget nudges belong at choke points.** A first draft bolted
  `WidgetRefresher.reload()` onto `deleteCardio` alone; the review pointed out
  the same argument applies to deleting the very session the widget shows.
  The nudge moved into `HistoryModel.mutate`/`attempt` (every History write)
  and onto the restore path in Settings — a backup restored onto a fresh
  install now populates the widget without waiting for the hourly backstop.
- Smaller: the 30-day window math is single-sourced
  (`CardioAnalytics.windowStart`) so the store fetch bound and the analytics
  filter can't disagree; the import idempotency state collapsed to one
  "remaining skips" dictionary; the fingerprint joins on the unit-separator
  control character so free text containing a printable delimiter can't
  collide two bouts; chart accessibility labels share one cached
  `DateFormatter` (`ChartDateLabel`) instead of allocating per mark.

Declined as out of scope: generalizing count-based idempotency to sessions
(a behavioral change to shipped import semantics — the session fingerprint's
collapse flaw stays documented above), and moving `CardioTrendsModel.load`
off the main actor (it mirrors the supplement card's precedent and reads a
30-day indexed window).

## Not compiled here

No Swift toolchain on this host (same as 016/025): the suite runs on macOS via
`scripts/run_tests.sh` / the `ios-tests.yml` workflow. Everything UI-free is
unit-tested (export contract, round-trip/idempotency/dry-run, analytics
bucketing and unit handling, reader precedence incl. malformed timestamps);
every new SQL statement was validated against the real v1+v2+v3 schema in
sqlite3, including the CHECK backstops. Device pass: the widget's `.lastCardio`
render in both families, the Progress cardio card (stacked legend, empty
states), and the Settings preview/confirm strings in situ.
