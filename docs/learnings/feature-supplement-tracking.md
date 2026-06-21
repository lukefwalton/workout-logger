# Feature — Daily supplement tracking (user request, off-spec)

A user-requested extra outside the v1.2 PR plan: a daily "did I take my creatine
today?" checklist on the Today tab — Creatine + Protein presets plus user-added
customs, checked off per day, with an optional **grams** amount for Protein and
**trends over time** in Progress.

## Where it lives changed mid-build — and that's the interesting part

The first cut stored this in `UserDefaults` (today-only recall, no migration). The
user then asked for it in the database — "one source of truth, and people might be
interested to see their trends over time." That's the right call for something with
history, so it moved into SQLite, which meant the project's **first real schema
migration**: bumping `Schema.latestVersion` 1 → 2.

The migration framework was already forward-only via `PRAGMA user_version`, so v2 was
clean to add: a fresh install lays down v1 + v2 in one transaction; an existing
v1.2-era DB (has `slug`) runs the `version < 2` step to add the tables; a pre-v1.2
legacy DB is still rejected by the `slug` guard *before* the forward step. Validated
the whole path (forward-migrate, upsert, cascade delete, grams CHECK) in `sqlite3`
before porting, and added a Swift test that stamps a v1 DB and asserts it migrates.

## Two tables, presence = taken

`supplements` is the configured list (presets first, `tracks_grams` flag, `sort_order`);
`supplement_intake` is one row per supplement per local day, where the row's
*existence* means "taken" and `grams` is an optional `REAL` (CHECK ≥ 0). Toggling is
insert/delete; editing grams is an `ON CONFLICT(supplement_id, day) DO UPDATE` upsert,
so a day can never have two rows for one supplement. Removing a custom supplement
cascades its intake. Presets seed once via `seedSupplementsIfNeeded()` (idempotent,
mirrors the exercise seed) at app bootstrap.

## Doctrine held: still the single write path

Even though it's not workout data, it goes through the same discipline — every mutation
is an `@MainActor WorkoutStore` method (`setSupplementIntake`, `addSupplement`,
`removeSupplement`, `seedSupplementsIfNeeded`) wrapped in `try db.transaction`; reads
(`supplements`, `supplementIntake(onDay:)`, `supplementHistory(sinceDay:)`) stay
non-isolated. No feature code runs ad hoc SQL. Day keys are centralized in one
`SupplementDay` helper ('YYYY-MM-DD', local) so the Today card (today's key) and the
trend analytics (stepping back for streaks) agree exactly — string order = date order.

## Trends are pure and testable

`SupplementAnalytics` (the supplement sibling of `ProgressAnalytics`) takes the list +
raw intake rows + a reference "today" and returns adherence (days taken / window),
current streak, and a Protein grams series — no store, no UI, unit-tested directly.
One deliberate streak nicety: the streak counts back from today, but if today isn't
checked yet it counts from yesterday, so it stays "alive" through the day instead of
reading 0 all morning. The Progress tab gained a "Supplements" section (adherence bars
+ streak + a protein-grams line chart) that **always renders**, even with zero workout
data — so someone tracking only supplements still has a Progress tab worth opening
(the workout charts degrade to an inline "no trends yet" card instead of taking over
the screen).

## Folded in the review feedback from the UserDefaults version

The bot's two flags on the first cut carried over into this rework: checks now clear
across midnight on app-foreground (`scenePhase`), not only `.onAppear`; and a rejected
add (blank / duplicate) surfaces a validation message (`SupplementModel.addError`)
instead of failing silently.

Not compiled here (Linux/no Xcode): schema/migration validated in sqlite3 + a Swift
migration test; store, model, and analytics are unit-tested; the card and Progress
section are correct-by-inspection and need the usual device pass.
