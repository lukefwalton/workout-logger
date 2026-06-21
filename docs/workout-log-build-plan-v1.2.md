# WorkoutChatLog — v1.2 Build Specification

A complete, self-sufficient build spec for a coding agent. Read it top to bottom, go
to the next unbuilt PR, implement that section, open a PR, get it reviewed, merge (or
hold), then move to the next. **Strictly sequential — no parallel work.** Each PR is a
self-contained gate with its own acceptance criteria and tests.

There are **zero installs** (never shipped, fully local), so this version is aggressive
about getting the schema and structure *right now*. The migration framework stays
intact so *post-launch* updates remain non-destructive — that's the future we're
protecting, not the past.

Out of scope: Apple Watch (no test hardware), dictation (system keyboard provides it).

**What changed from v1.1:**
- **Active workout session (PR 3).** The write path no longer creates one session per confirmed entry; confirmed sets append to one open session until the user finishes it. Foundational — History, Progress, Health, calories, and the widget depend on it.
- **Exercise identity model (PR 2).** Flat canonicals with a stable `slug`, a `family_key`, owned (unambiguous) aliases, and primary/secondary muscles. Variations are separate canonicals; families are for browsing/optional rollups, never default PR/chart collapse.
- **LLM is draft-or-clarification-or-declined (PR 8)**, not parse-or-fail.
- Added: edit logged set (PR 4), post-fill/manual session times (PR 3/4/11), rename/merge exercises (PR 9), import (PR 13), OCR capture (PR 14, optional).

---

## 0. How the agent should work this document

1. Find the lowest-numbered PR not yet merged.
2. Read that PR section in full, plus §1 (doctrine), §1.1 (resolution + identity), §2 (canonical types).
3. Implement exactly that PR. Do not pull work forward from later PRs.
4. Run the existing test suite + the tests listed in the PR. They must pass.
5. Open a PR with the listed acceptance criteria in the description.
6. A human reviews: merge, request changes, or hold. Do not start the next PR until the current one is merged.
7. Repeat.

If this spec and any older "implementation packet" disagree, **this spec wins.**

---

## 1. Doctrine (do not violate)

- No account, no server, no subscription, no tracking. On-device SQLite is the only source of truth.
- **Model proposes → app confirms → app writes.** Nothing — regex, fuzzy, embeddings, OCR, or LLM — writes to the DB or mutates analytics. They produce a *draft* or a *question*; a human confirms before anything is written.
- All writes go through `WorkoutStore` APIs. **Sets** are created only through `save(_:into:)`. Exercises are created through `addExercise`, seeding, or merge (PR 9). Deletes/edits/merges/finish/session-edits go through dedicated `WorkoutStore` APIs. No feature code runs ad hoc SQL. The widget (PR 12) is read-only.
- **The single-connection write invariant has compiler teeth.** Every *mutating* `WorkoutStore` API (`save`, `startSession`, `finishSession`, `updateSession`, `deleteSet`, `deleteSession`, `updateSet`, `addExercise`, `renameExercise`, `mergeExercise`, `seedExercisesIfNeeded`, `migrate`) is `@MainActor` (applied in PR 2). Reads stay non-isolated so the widget's separate process and background reads still compile. No serial queue/actor; do not mark the whole store `@MainActor`.
- **One active session at a time** (PR 3): created lazily on the first saved set, appended to until finished, never left empty.
- **Exercise identity is flat and canonical** (§1.1, PR 2): aliases collapse into one canonical; meaningful variations are separate canonicals; families group related canonicals for browsing and optional rollups, but never collapse progression or PRs by default.
- On-device entitlements only: App Group (PR 1), HealthKit (PR 10), and Camera (PR 14, optional). HealthKit and OCR are opt-in; the app is fully functional without them. Never write an estimated calorie value into HealthKit energy data.
- No regulated-health or coaching claims (Foundation Models acceptable-use). Calorie and feel data are honest, user-entered or clearly-estimated, never diagnostic.
- Existing unit tests pass at every PR boundary.

### 1.1 The resolution stack and the exercise identity model

**Resolution stack ("Disneyland" model).** The ride is on rails; the LLM is the
animatronics that make it feel alive and the cast member who rescues a broken ride.
**Determinism first, ML second, LLM last.**

| Layer | Mechanism | Determinism | When |
| --- | --- | --- | --- |
| 0 | Exact canonical match | deterministic | always first |
| 1 | Alias match (owned, unambiguous) | deterministic | exact misses |
| 2 | Fuzzy string match (edit distance + token) | deterministic | exact + alias miss — **PR 7** |
| 3 | On-device embeddings (`NLContextualEmbedding`) | ML, gated | fuzzy low-confidence — **PR 7** |
| 4 | Foundation Models — draft **or clarification** | ML, gated | everything else — **PR 8** |

**Iron rules for every layer ≥ 2:** (1) it **proposes** (a candidate, draft, or
question); the user **confirms** — never auto-apply. (2) It resolves an *unrecognized
token to an existing canonical*; it **never merges two distinct canonicals.**

**Exercise identity (the data model).** The governing rule:

> **Exercise identity is flat and canonical. Aliases collapse into one canonical.
> Meaningful variations are separate canonicals. Families group related canonicals for
> browsing and optional rollups, but never collapse progression or PRs by default.**

Concretely:
- **If performance meaningfully differs, it is a separate canonical exercise.** Push-Up, Close-Grip Push-Up, Diamond Push-Up, Decline Push-Up, Incline Push-Up, Weighted Push-Up are *six canonicals*, not one with variations. Same for the pull-up family, the row family, etc. The variant dimensions that usually justify a separate canonical: **grip** (close/wide/neutral/reverse), **angle** (incline/flat/decline), **equipment** (barbell/dumbbell/cable/machine/smith), **load mode** (bodyweight/weighted/assisted), **stance** (conventional/sumo/split/Bulgarian), **laterality** (single-arm vs. bilateral). This list is the *human rubric for authoring the seed* — it is not a set of columns (see PR 2).
- **Stable identity ≠ display name.** The immutable identity that `sets.exercise_id` references is the integer rowid — it never changes when a name changes. A separate stable `slug` (`"close_grip_push_up"`) is the seed/import key. Display names are mutable; nothing logged points at them.
- **Aliases are owned by exactly one canonical and are unambiguous.** `chest dip → Chest Dip`, `triceps dip → Triceps Dip`, `bench dip → Bench Dip`. A bare ambiguous term like `dip` is **not** an alias of anything — it falls through to fuzzy/LLM, which *asks* (PR 8). This is enforced in the schema (PR 2), not just by convention.
- **Families are non-analytical by default.** `family_key` groups canonicals for browsing and optional, explicitly-chosen rollups. PRs and progress charts compare a canonical only to itself. A "family view" is opt-in, never the default.
- **Muscles roll up; exercises do not.** `primary_muscle` drives per-muscle volume (PR 5). `secondary_muscles` is stored but not counted at launch (deferred fractional weighting).
- **Don't explode variations at launch.** Seed the common, meaningful variants; let users create custom canonicals (which still get a `family_key` when they match a known family); promote frequently-created customs into the seed later via a slug'd seed update.

Worked example — "romanian deadlift" hits the **RDL alias** (Layer 1) → *Romanian
Deadlift*; it never reaches fuzzy and must never map onto *Deadlift* (different
muscles; collapsing them corrupts per-muscle analytics). The layer ordering plus the
flat-canonical model enforce this.

---

## 2. Canonical types

Load-kind is already implemented; `SetDraft` is **flat** — do not introduce a nested
`load:`.

```swift
// Model/WorkoutDraft.swift — WRITE side
enum WeightUnit: String, Codable, CaseIterable { case lb, kg }
enum SetType: String, Codable, CaseIterable { case working, warmup, dropset, myorep, amrap, backoff }
enum WorkoutLoadKind: String, Codable, CaseIterable { case external, bodyweight, unspecified, bodyweightPlus, assisted }

enum SessionFeel: String, Codable, CaseIterable {           // SF Symbols, never emoji
    case solid, neutral, off
    var label: String { switch self { case .solid: "Solid"; case .neutral: "OK"; case .off: "Off day" } }
    var symbol: String { switch self { case .solid: "arrow.up.circle.fill"; case .neutral: "equal.circle.fill"; case .off: "arrow.down.circle.fill" } }
}

struct SetDraft: Identifiable, Equatable {
    let id = UUID()
    var exerciseName: String
    var weight: Double
    var unit: WeightUnit
    var loadKind: WorkoutLoadKind = .external
    var reps: Int
    var rir: Int?
    var setType: SetType = .working
    var notes: String?
    var sourceText: String?
}

struct WorkoutDraft: Identifiable {
    let id = UUID()
    var startedAt: Date
    var name: String? = nil
    var notes: String? = nil
    var sets: [SetDraft]
    var feel: SessionFeel? = nil      // defaults REQUIRED so existing call sites keep compiling
    var isDeload: Bool = false
}
```

```swift
// Exercise identity (PR 2). `id` is the immutable identity sets reference; `slug` is the stable seed/import key.
struct Exercise: Equatable {
    let id: Int64                       // immutable rowid — what sets.exercise_id points to
    let slug: String                    // stable seed/import key, e.g. "close_grip_push_up" (UNIQUE)
    var canonicalName: String           // display, mutable
    var familyKey: String?              // e.g. "push_up"; nil = singleton; non-analytical by default
    var primaryMuscle: String?          // drives per-muscle analytics (PR 5)
    var secondaryMuscles: [String]      // stored (JSON), not counted at launch
    // aliases live in their own table, owned 1:1 (see PR 2)
}

// Read snapshot of the open session (PR 3). The DB row is the source of truth.
struct OpenSession: Equatable {
    let id: Int64
    let startedAt: Date
    let lastSetAt: Date?     // nil only transiently; sessions open lazily on first set
    let name: String?
    let setCount: Int
}
```

```swift
// Storage/WorkoutStore.swift — READ side
struct WorkoutLoad: Codable, Equatable {
    var kind: WorkoutLoadKind
    var amount: Double?
    var unit: WeightUnit?
    var displayText: String   // "135 lb" | "BW" | "unspecified" | "BW + 25 lb" | "assisted 30 lb"
}
```

---

## 3. PR map

| PR | Title | Depends on | Schema |
| --- | --- | --- | --- |
| 1 | Foundation: App Group + shared DB + privacy policy | — | none |
| 2 | Schema reset + hardening (exercise identity model + full session schema) | 1 | reset to clean v1 |
| 3 | **Active workout session lifecycle + annotations** (+ post-fill/manual times) | 2 | none |
| 4 | History: view + delete + edit (set & session) | 3 | none |
| 5 | Progress charts + honest analytics (canonical-only; primary-muscle rollups) | 3, 4 | none |
| 6 | (reserved — folded into 5) | — | — |
| 7 | Layered exercise resolution (fuzzy + embeddings, family-aware) | 2 | none |
| 8 | Foundation Models: draft · clarification · declined | 7 | none |
| 9 | Rename / merge exercises (Settings) | 7 | none |
| 10 | Apple Health (optional, opt-in) | 1, 3 | none |
| 11 | Calorie estimate (session-bounds precedence) | 3, 10 | none |
| 12 | Home Screen widget (current / last workout) | 1, 3 | none |
| 13 | Import (JSON restore; CSV stretch) | 2 | none |
| 14 | OCR capture (sheet → parse pipeline) — *optional / post-launch candidate* | 8 | none |
| 15 | App Store submission readiness | all | none |

Critical: **PR 3 before 4, 5, 10, 11, 12** (anything reading a "session" needs real
sessions). **PR 2 before 7/9** (resolution and merge need the identity model). 6 is
intentionally folded into 5.

---

## PR 1 — Foundation (App Group, shared DB, privacy policy)

**Goal:** put the DB where the widget and HealthKit can reach it; satisfy the App
Store privacy requirement. No relocation — zero installs.

**Files:** `App/AppDatabase.swift`, `project.yml`, `docs/privacy.md`.

- Add App Group `group.com.<you>.workoutchatlog` to the app target (`project.yml` `entitlements` + `com.apple.security.application-groups`).
- `AppDatabase.makeStore()` opens the SQLite file from the App Group container:

```swift
guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.<you>.workoutchatlog")
else { throw DBError.containerUnavailable }   // fail loudly in dev
let url = base.appendingPathComponent("workout.sqlite")
let store = WorkoutStore(db: try SQLiteDB(path: url.path))
try store.migrate(); try store.seedExercisesIfNeeded(ExerciseSeed.load()); return store
```

- `docs/privacy.md`: no account/server/analytics/tracking; all data on-device; HealthKit read with permission, never transmitted. Host before submission.

**Acceptance:** builds with the App Group entitlement; DB opens from the container; existing tests pass; a second target can open the same file.

---

## PR 2 — Schema reset + hardening (exercise identity model + full session schema)

Zero installs → collapse to one clean canonical schema and bake in everything the
identity model (§1.1) and the session model (PR 3) need, so later PRs are not built on
a half-schema.

**2a — Canonical schema (`latestVersion = 1`, delete any v2 ALTER path).** Single v1
literal with every CHECK present.

```sql
CREATE TABLE workout_sessions (
    id INTEGER PRIMARY KEY,
    started_at TEXT NOT NULL,
    ended_at  TEXT,                          -- NULL = open/in-progress (at most one such row)
    name TEXT,
    notes TEXT,
    feel TEXT,                               -- SessionFeel rawValue or NULL
    is_deload INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);

CREATE TABLE exercises (
    id INTEGER PRIMARY KEY,                  -- immutable identity; sets.exercise_id references this
    slug TEXT NOT NULL UNIQUE,               -- stable seed/import key, e.g. "close_grip_push_up"
    canonical_name TEXT NOT NULL,            -- display, mutable
    family_key TEXT,                         -- e.g. "push_up"; NULL = singleton; non-analytical by default
    primary_muscle TEXT,
    secondary_muscles TEXT NOT NULL DEFAULT '[]',  -- JSON array of muscle strings (stored, not counted at launch)
    is_custom INTEGER NOT NULL DEFAULT 0,    -- user-created vs seeded
    created_at TEXT NOT NULL
);
CREATE INDEX idx_exercises_family ON exercises(family_key);
CREATE INDEX idx_exercises_muscle ON exercises(primary_muscle);

-- One alias -> exactly one canonical. The PRIMARY KEY is the global-uniqueness guarantee:
-- an ambiguous term cannot be inserted as an alias of two lifts, so it falls through to suggest/clarify.
CREATE TABLE exercise_aliases (
    alias TEXT PRIMARY KEY,                  -- normalized: lowercased, punctuation/space-collapsed
    exercise_id INTEGER NOT NULL REFERENCES exercises(id) ON DELETE CASCADE
);

CREATE TABLE sets (
    id INTEGER PRIMARY KEY,
    session_id INTEGER NOT NULL REFERENCES workout_sessions(id) ON DELETE CASCADE,
    exercise_id INTEGER NOT NULL REFERENCES exercises(id),
    set_index INTEGER NOT NULL,
    weight REAL, unit TEXT, load_kind TEXT NOT NULL CHECK (load_kind IN ('external','bodyweight','unspecified','bodyweightPlus','assisted')),
    reps INTEGER NOT NULL CHECK (reps BETWEEN 1 AND 100),
    rir INTEGER CHECK (rir IS NULL OR rir BETWEEN 0 AND 10),
    set_type TEXT NOT NULL, notes TEXT, created_at TEXT NOT NULL,
    UNIQUE(session_id, set_index)
);
```

The `migrate()` framework and `PRAGMA user_version` stay for genuine post-launch
migrations.

**2b — Seed (`seed_exercises.json`) gains `slug`, `family_key`, `secondary_muscles`.**
Each seed entry:

```json
{
  "slug": "close_grip_push_up",
  "canonical_name": "Close-Grip Push-Up",
  "family_key": "push_up",
  "primary_muscle": "triceps",
  "secondary_muscles": ["chest", "shoulders"],
  "aliases": ["military pushup", "triceps pushup", "close grip pushup"]
}
```

- **Reseed upserts on `slug`** (not name): existing slug → leave user edits alone (or update muscle/family metadata only, never the user's renamed `canonical_name`); new slug → insert. This is what makes a post-launch seed expansion non-destructive.
- **Backfill `family_key`** on the existing 89 lifts (most fall into obvious families: bench, squat, deadlift, row, curl, press, push_up, pull_up, …; singletons keep `family_key = NULL`).
- **Audit aliases:** no alias string may appear under two canonicals; remove ambiguous bare terms (`dip`, `row`, `curl`, `press`, `fly` alone, etc.) — those are meant to fall through to suggest/clarify. Normalize on insert.

**2c — Parser rep cap.** `WorkoutValidator.maxReps = 100` and `DeterministicParser` uses that shared range, so `1x150` declines at parse instead of confirm-then-reject at save.

**2d — `@MainActor` on every mutating store API** (§1). Reads stay non-isolated; an off-main write must fail to compile.

**2e — NOTICE.md** says 71 lifts; it's 89. Fix it.

**Acceptance:** fresh DB at `user_version = 1` with the full exercise + session schema and all CHECKs; the seed loads with slugs, families, and owned aliases; **no alias maps to two canonicals**; reseeding the same JSON is a no-op (idempotent on slug); `1x150` declines at parse; mutating APIs are `@MainActor` (off-main write won't compile); reads callable off-main; NOTICE reads 89; all tests pass.

**Tests:** seed alias-uniqueness (assert every alias resolves to exactly one exercise); reseed idempotency on slug; out-of-vocabulary `load_kind` insert rejected by CHECK; parser declines 101+ reps; seed loads 89.

---

## PR 3 — Active workout session lifecycle + annotations

**Goal:** confirmed sets append to one open session until the user finishes it; fix the
per-entry-session bug that would otherwise corrupt History, Progress, Health,
calories, and the widget. Session-level notes/feel/deload are set at finish. Sessions
may also be created/backdated and have their times set manually (post-fill).

**Store APIs (all `@MainActor`, transaction-wrapped).**

```swift
func currentOpenSession() throws -> OpenSession?    // read (non-isolated ok)

@MainActor func startSession(name: String? = nil, startedAt: Date = Date()) throws -> Int64

// Append a draft's sets to `sessionID`, or open a new session if nil. Returns the session used.
@MainActor @discardableResult
func save(_ draft: WorkoutDraft, into sessionID: Int64?) throws -> SaveResult   // SaveResult gains `sessionID`

// Close a session: set ended_at + metadata. If it has zero sets, delete it instead.
@MainActor func finishSession(_ id: Int64, endedAt: Date = Date(),
                              name: String?, notes: String?, feel: SessionFeel?, isDeload: Bool) throws
```

Keep the existing `save(_ draft:)` as `save(draft, into: nil)` so current callers/tests compile.

**THE critical detail — `set_index` continuation.** `sets` has
`UNIQUE(session_id, set_index)`. When appending into an existing session, new indices
start at `MAX(set_index) + 1` for that session, **not** at 1 — restarting collides on
the second entry and throws. In `save(_:into:)`:
`let base = (SELECT COALESCE(MAX(set_index),0) FROM sets WHERE session_id = ?)`; new
sets get `base+1, base+2, …`.

**Lazy creation, single open session.** Never open a session eagerly — open on the
first saved set, so empty sessions can't exist. Enforce at most one open session.

**Stale auto-finish (prevents "yesterday eats today").** `TodayModel` reconciles on
appear/before logging: if `currentOpenSession()` exists and its `lastSetAt ??
startedAt` is on a different local calendar day than now, or the gap exceeds a typed
threshold (default 6h), auto-`finishSession` it (no metadata) and let the next save
open a fresh session. Otherwise adopt it as active.

**Post-fill / backdated sessions.** `startSession(startedAt:)` accepts an arbitrary
past date, so a user can log a workout that happened earlier. Editing a session's
times after the fact lives in PR 4 (`updateSession`).

**TodayModel.**

```swift
@Published private(set) var activeSessionID: Int64?
@Published private(set) var activeSessionSetCount = 0
// save:   let r = try store.save(draft, into: activeSessionID); activeSessionID = r.sessionID; refresh count
// finish: try store.finishSession(activeSessionID!, name:notes:feel:isDeload:); activeSessionID = nil
// appear: reconcile stale open session (above), else adopt it
```

Logging appends to the single active session regardless of free-form vs plan mode; the
plan checklist's `loggedSetCount` is UI state layered on top.

**UI.** Today shows an active-workout banner when a session is open: "Current workout ·
N sets" + **Finish workout**. Finish presents the optional feel control (Solid / OK /
Off day with SF Symbols), a deload toggle, and a notes field, then closes the session.

**Reads/export.** `WorkoutSetHistoryRow` gains `sessionFeel: SessionFeel?`,
`sessionIsDeload: Bool`, `sessionEndedAt: String?`. `ExportedSession` gains
`ended_at`/`feel`/`is_deload` (bump export `schema_version` to 2).

**Acceptance:** two entries in a row land in **one** session with continued `set_index`
(no UNIQUE error); "Finish workout" closes it and the next entry opens a new one; an
open session from a prior day auto-finishes and does not absorb today's sets; a session
never exists with zero sets; a backdated `startSession` creates a session dated in the
past; feel/deload/notes persist and round-trip through `setHistory` and export.

**Tests:** append continues `set_index` (2 entries → one session, indices 1..n, no
collision); lazy open (no row until first save); single-open invariant; stale
auto-finish (open session dated yesterday → new session today); finish on empty session
deletes it; backdated session; feel/deload/notes round-trip.

---

## PR 4 — History: view + delete + edit (set & session)

**Goal:** a session-grouped list of saved sets (now real, multi-set sessions), showing
feel/notes, with delete and edit — including editing session times (post-fill).

**Files:** `Features/History/HistoryModel.swift`, `Features/History/HistoryView.swift` (rewrite placeholder), `App/RootTabView.swift` (history line), `Storage/WorkoutStore.swift` (delete + edit APIs).

**Model.** `@MainActor` `ObservableObject`; `State { loading, loaded([Section]), empty, failed }`. `load()` reads `setHistory(since: nil, includeNotes: true)`, groups by `sessionID`, sorts by `startedAt` desc; each section carries title (session name or formatted date via a cached `DateFormatter`), set count, feel, deload, and start/end times.

**Delete (transaction-wrapped, scoped to the set's own session).**

```swift
@MainActor func deleteSet(_ id: Int64) throws {
    try db.transaction { let parent = try sessionID(ofSet: id); try deleteSetRow(id); if let parent { try deleteSessionIfEmpty(parent) } }
}
@MainActor func deleteSession(_ id: Int64) throws { try db.transaction { try deleteSessionRow(id) } }  // sets cascade
```

**Edit set (new mutating writer).**

```swift
@MainActor func updateSet(_ id: Int64, exerciseName: String, weight: Double, unit: WeightUnit,
                          loadKind: WorkoutLoadKind, reps: Int, rir: Int?, setType: SetType, notes: String?) throws
```

- Re-validate with `WorkoutValidator` (reps 1…100, rir 0…10, weight finite ≥ 0); reject invalid.
- Editing the exercise name re-resolves through the registry (exact→alias→create), same as save; PR 7 suggestions can be offered here once they exist.
- v1 simplification: editing does **not** recompute PR/achievement detection. Note it; revisit later.

**Edit session (post-fill / manual times).**

```swift
@MainActor func updateSession(_ id: Int64, name: String?, startedAt: Date?, endedAt: Date?,
                              notes: String?, feel: SessionFeel?, isDeload: Bool) throws
```

- Lets the user fix or post-fill `started_at`/`ended_at`, name, feel, deload, notes after the fact. If the UI offers a duration instead of an end time, compute `endedAt = startedAt + duration`. Validate `endedAt >= startedAt` when both set.

**UI.** Per row: swipe Edit / Delete. Per section: edit session (name, times/duration,
feel, deload, notes) and Delete workout. Loading/empty/error via
`ContentUnavailableView`; `.task { load() }` + `.refreshable`.

**Acceptance:** real multi-set sessions render grouped with feel/notes/times; edit-set
changes fields and persists; an invalid edit is rejected with a message (no bad write);
edit-session changes times/duration and metadata (and rejects end < start);
delete-set in a multi-set session leaves the session; deleting the last set or the
session removes it; no UI issues SQL.

**Tests:** grouping/sort; `updateSet` persists + re-validates (rejects reps=0); edit
re-resolves a changed exercise name; `updateSession` sets times (and duration→endedAt)
and rejects end < start; delete behaviors via `sessionCount()`/`setCount()`.

---

## PR 5 — Progress charts + honest analytics

**Goal:** Swift Charts for e1RM, volume, per-muscle weekly hard sets, and a reps trend
for bodyweight lifts — over **real sessions**, **canonical-only** (never family
collapse) — with off-day/deload sessions excluded from trends (toggleable).
Deterministic only.

**Canonical-only by default.** Charts and PRs compare an exercise to itself
(`exercise_id`). `family_key` is **not** used to aggregate progression. A "family view"
(all push-up variants together) is a future opt-in toggle, off by default — never the
default chart.

**Honest analytics policy.** Extend `AnalyticsPolicy`:

```swift
var excludeOffDays = true        // a sick day shouldn't read as regression
var excludeDeloadSessions = true
func countsTowardTrend(feel: SessionFeel?, isDeload: Bool) -> Bool {
    if excludeDeloadSessions, isDeload { return false }
    if excludeOffDays, feel == .off { return false }
    return true
}
```

Surface `excludeOffDays` as a toggle (default on). Excluded sessions still show in
History — only dropped from *trend* math. Nothing is hidden.

**Aggregates (per session).**
- **e1RM:** per (exercise, session), `max` over `.external` sets of `amount*(1+reps/30)` (Epley); drop reps > 12. One point per session.
- **Volume:** per (exercise, session), `sum` of `amount*reps` over `.external` sets. One bar per session.
- **Bodyweight reps trend:** for predominantly `.bodyweight`/`.unspecified` exercises, max/total reps per session instead of e1RM/volume — no empty Progress tab for calisthenics.
- All filtered through `policy.countsTowardTrend(feel:isDeload:)`.

**Per-muscle weekly hard sets (primary muscle only at launch).** `WorkoutSetHistoryRow`
gains `primaryMuscle: String?` (select `e.primary_muscle`); bucket by ISO week; count
hard sets via `AnalyticsPolicy.isHardSet`; stacked bars by muscle; `nil` → "Untagged".
`secondary_muscles` is stored but **not** counted at launch (fractional weighting is a
deliberate deferral; revisit with a weighting policy).

**Acceptance:** loaded lifts show one e1RM point + one volume bar per real session;
bodyweight-only lift shows a reps trend; per-muscle weekly bars render from primary
muscle; charts never mix two canonicals (no family collapse); toggling exclude-off-days
removes flagged sessions from trends while History keeps them; no AI touches a number.

**Tests:** e1RM top set per session; volume sums the session; off/deload excluded when
policy says so and included when toggled off; hard-set count matches the policy; two
canonicals in the same family never appear in the same progression series.

---

## PR 7 — Layered exercise resolution (fuzzy + embeddings, family-aware)

**Goal:** when exact + alias miss, *propose* the right existing canonical via
deterministic fuzzy matching, then optionally on-device embeddings. User always
confirms. Distinct canonicals never merged (§1.1). Ambiguous bare terms (which by
design aren't aliases) land here and surface a choice.

Adds a non-mutating `suggestExercises(for:)` returning ranked candidates; does not
change `resolveExercise`'s contract.

**Layer 2 — fuzzy (deterministic workhorse).** Normalized Levenshtein over
`canonical_name` + aliases + a token-overlap bonus; keep score ≥ 0.70, ranked, top 3.
Generous threshold is safe because nothing auto-applies ("dops"→"Dip" is 0.75).

```swift
struct ExerciseSuggestion: Equatable {
    let exerciseID: Int64; let canonicalName: String; let familyKey: String?
    let score: Double; let via: Via; enum Via { case fuzzy, semantic }
}
func suggestExercisesFuzzy(for raw: String, limit: Int = 3) throws -> [ExerciseSuggestion]
```

**Family-aware ranking (hint only, never a gate).** When the query clearly names a
family token ("pushup", "dip"), candidates sharing that `family_key` may be grouped/
ranked together so the user sees *all* the dip variants to pick from — but the suggester
still **proposes**; it never auto-picks one family member over another.

**Layer 3 — embeddings (on-device, ML, gated — the swing).** Native
`NLContextualEmbedding` (Apple Natural Language; BERT-style; model assets in the
**system** catalog → zero app-size). Use only when Layer 2's best < ~0.85. **Build
behind `#if canImport(NaturalLanguage)` + a runtime availability check; verify exact
symbols/OS floor in Xcode.** It returns per-token vectors (mean-pool via Accelerate
vDSP), downloads assets async, and is documented to fail to load in the simulator — gate
it like Foundation Models and fall through to fuzzy/FM on any failure. Embed the
canonical names once (cache vectors in memory); cosine-rank; keep ≥ ~0.80. Never block
the UI.

**Confirm UX.** When a save would create a new exercise and there are candidates, show
"Did you mean **Triceps Dip**? / **Chest Dip**? / **Bench Dip**?" above the
new-exercise notice. Tapping sets the name to that canonical. Declining creates the new
canonical (with a generated `slug`, `is_custom = 1`, and `family_key` if the family is
obvious).

**Guardrail (enforced by ordering + owned aliases):** suggestions only appear when exact
+ alias both miss, so an aliased lift (RDL, OHP, …) is never "corrected" onto a different
lift; and because aliases are unambiguous, a bare ambiguous term has no alias to hit and
correctly reaches this layer.

**Acceptance:** **Fuzzy (Layer 2) alone is the shippable bar; embeddings (Layer 3) are
opportunistic — do not block this PR on them.** Assets unavailable/simulator weird →
silent fall-through, PR still merges. With that: `dops` surfaces "Did you mean Dip
variants?"; `triceps dip` (owned alias) resolves directly with no suggestion; bare `dip`
(no alias) surfaces the dip family to choose from; `romanian deadlift` resolves to RDL,
never associated with Deadlift; declining creates a new custom canonical.

**Tests (fuzzy fully tested; embeddings not relied on):** `dops`→Dip family ranked;
`bnch press`→Bench Press first; `rdl` resolves directly (suggester not consulted); bare
`dip` returns multiple dip canonicals (no auto-pick); `asdfqwer`→no suggestions.

---

## PR 8 — Foundation Models: draft · clarification · declined (the LLM layer)

**Goal:** when `DeterministicParser.parse` returns nil, the on-device LLM gets one shot
to either produce a **draft proposal** or ask a **short clarification question** — not
just fail. No write power: it proposes or asks; the user confirms.

**Outcome shape (common code, no FM symbols).**

```swift
enum ParseOutcome: Equatable {
    case draft(WorkoutParseResult)
    case clarification(ClarificationPrompt)
    case declined
}
struct ClarificationPrompt: Equatable {
    let message: String              // < 12 words
    let suggestedReplies: [String]   // ≤ 3, e.g. ["Dumbbell Bench Press", "Dumbbell Fly", "Type it manually"]
}
protocol WorkoutParsing { func parse(_ input: String, context: [String]) async -> ParseOutcome }
```

The deterministic path returns `.draft` or `.declined` only — it never asks. Only the FM
layer returns `.clarification`.

**Total module isolation (highest compile-risk PR).** No `FoundationModels` symbol in
always-compiled code. The protocol + `ParseOutcome`/`ClarificationPrompt`/
`WorkoutParseResult` + the orchestrator live in common code (Foundation only).
`FoundationWorkoutParser`, the `@Generable` types, and `isModelAvailable()` live entirely
inside `#if canImport(FoundationModels)`. Tests drive the protocol with a fake; they
never import `FoundationModels`.

**API symbols:** `SystemLanguageModel`, `LanguageModelSession`, `respond(to:generating:)`,
`@Generable`, `@Guide`. **Gate at compile (`#if canImport(FoundationModels)`) + runtime
(`SystemLanguageModel.default.availability`); verify exact availability in Xcode** — the
installed SDK symbols are the source of truth, not a version quoted here.

```swift
#if canImport(FoundationModels)
import FoundationModels
func isModelAvailable() -> Bool {
    switch SystemLanguageModel.default.availability {
    case .available: return true
    case .unavailable(.deviceNotEligible), .unavailable(.appleIntelligenceNotEnabled), .unavailable(.modelNotReady): return false
    @unknown default: return false
    }
}
#endif
```

**Output type.**

```swift
@Generable struct ModelParseResponse {
    @Guide(description: "draft, clarification, or declined") var kind: String
    @Guide(description: "Parsed workout draft if kind is draft.") var workout: ModelWorkoutParse?
    @Guide(description: "Short clarification question (< 12 words) if kind is clarification.") var clarificationQuestion: String?
    @Guide(description: "Up to 3 suggested reply buttons for a clarification.") var suggestedReplies: [String]
    @Guide(description: "Short warning if the input was ambiguous; else empty.") var warning: String
}
@Generable struct ModelWorkoutParse {
    @Guide(description: "Canonical exercise name, title-cased if possible.") var exerciseName: String
    @Guide(description: "One or more parsed sets.") var sets: [ModelSetParse]
    @Guide(description: "True if this looks like an exercise not in the known list.") var isNewExercise: Bool
}
@Generable struct ModelSetParse {
    @Guide(description: "Weight amount; 0 if bodyweight/unspecified.") var amount: Double?
    @Guide(description: "lb or kg; null if not stated.") var unit: String?
    @Guide(description: "external, bodyweight, unspecified, bodyweightPlus, or assisted.") var loadKind: String
    @Guide(description: "Reps, 1–100.") var reps: Int
    @Guide(description: "Reps in reserve, 0–10; null if not stated.") var rir: Int?
    @Guide(description: "working, warmup, dropset, myorep, amrap, or backoff.") var setType: String
}
```

**Rules (put in `instructions`, with `store.exerciseNames(limit:)`; user text goes in `prompt`):**
- If you can confidently parse exercise + reps + load + set count → `kind = "draft"`.
- If one or two fields are missing but it's clearly workout logging → `kind = "clarification"` with a question < 12 words and up to 3 suggested replies.
- If it isn't a workout log → `kind = "declined"`.
- **Never invent** reps, load, RIR, exercise identity, or set count.

**Mapping `ModelParseResponse` → `ParseOutcome` (defensive).**
- `kind == "draft"` and `workout` non-nil and every set valid (reps 1…100, known enums) → `.draft`. **All-or-nothing:** if any set is unreadable, do not silently drop it — return `.declined` (or, if intent is clearly logging, the model should have returned clarification). Map model sets to the **flat** `SetDraft`.
- `kind == "clarification"` with a non-empty question → `.clarification` (cap `suggestedReplies` at 3; always append "Type it manually" in the UI).
- Anything else (unknown kind, draft with nil workout, clarification with empty question) → `.declined`.

**Clarification follow-up (capped state machine).** `TodayModel.Status` gains
`needsClarification(ClarificationPrompt)`:

```swift
enum Status { case idle, declined, needsClarification(ClarificationPrompt), saved(Int), failed(String) }
```

- On `.clarification`: store the prompt + the original input; show the question + suggested-reply buttons + a "Type it manually" button.
- Tapping a reply re-invokes `parse(originalInput, context: [previousReplies…])` (the original text is preserved as context; the chosen reply is appended). Result may be `.draft` (→ confirm card), another `.clarification` (→ ask again), or `.declined`.
- **Round cap = 2.** After two clarification rounds without a draft → `.declined` with "Type it manually." "Type it manually" at any point clears the clarification and returns to normal input.

**Optional bridge (commentary → annotation, clearly marked optional).** If the model
classifies the input as commentary rather than a set (e.g., "felt smoked today"), the UI
may offer to attach it to the active session as a **note** or set **feel = .off** instead
of just declining — still proposing, never writing on its own. Keep behind the same
confirm gate. Don't block the PR on it.

**Orchestrator order:** deterministic parse → if `.declined` and FM available, FM →
else `.declined`. Any FM `.draft` still flows through the confirm card and
`WorkoutStore.save(_:into:)` → `WorkoutValidator`. **Do not add a second validator.**
Confirm card shows a "parsed with Apple Intelligence" note and the PR 7 new-exercise
suggestions.

**Acceptance:** builds and all tests pass with `FoundationModels` unavailable (no FM
symbol in common code); deterministic wins for "bench 135x8"; on a no-AI device an
unparseable entry → `.declined`, no crash; "did chest thing with 45s for a few" → a
clarification with ≤3 replies, not a hard fail; choosing a reply yields a draft or one
more clarification, capped at 2 rounds; a draft with one bad set declines wholesale;
nothing persists without confirm.

**Tests (fake `WorkoutParsing`):** FM fires only when deterministic returns `.declined`;
a faked `.clarification` drives `needsClarification` and the reply re-invokes parse with
context; round cap stops at 2 → `.declined`; mixed valid/invalid sets decline wholesale;
no save before confirm.

---

## PR 9 — Rename / merge exercises (Settings)

**Goal:** let users fix the duplicates that unknown-exercise creation inevitably
produces ("Lat Pulldown", "Lat Pull Down", "Pulldown Machine"), because duplicate
canonicals fragment progress charts. Settings → Exercises.

**Store APIs (all `@MainActor`, transaction-wrapped).**

```swift
@MainActor func renameExercise(_ id: Int64, to newName: String) throws       // changes canonical_name (display) only; id/slug unchanged
@MainActor func mergeExercise(from sourceID: Int64, into targetID: Int64) throws
```

**`mergeExercise` is one transaction:** `UPDATE sets SET exercise_id = target WHERE
exercise_id = source` → re-point source's aliases to target (respecting the global
alias-uniqueness PK; on collision keep the existing owner and drop the duplicate alias) →
add the source's old canonical name as an alias of target if free → `DELETE FROM
exercises WHERE id = source`. Guard: reject `source == target`; reject merging a seeded
lift *out of existence* if you'd rather keep seeds (optional policy — at minimum warn).

**Rename collision.** Renaming to a name that already exists as another canonical is a
likely "I meant to merge" → reject the rename and offer merge instead. (Display names
aren't required UNIQUE, but a silent duplicate is bad UX.)

**Merge is for duplicates, not variations.** The UI copy must be explicit: "This
permanently moves all sets from A into B and deletes A. Use it only for duplicates of
the same exercise — not for different variations (a Close-Grip Push-Up is not a
Push-Up)." `family_key` sameness is a *weak hint* the app can surface, **not** a gate —
the app can't know intent, so it warns and lets the user decide.

**UI.** Exercises list (search, grouped by `family_key`); per exercise: Rename, Merge
into…, and a usage count ("used in N sets"). Custom lifts deletable only when unused.

**Acceptance:** rename changes the display name everywhere without touching history
(same `id`/`slug`); merge re-points all sets, folds aliases without violating
uniqueness, deletes the source, and leaves charts intact (the target now owns the
combined history); self-merge and rename-onto-existing are blocked with a helpful
message.

**Tests:** merge re-points sets and deletes source in one transaction; alias collision
on merge keeps the existing owner; rename preserves `id`/`slug` and set associations;
self-merge rejected.

---

## PR 10 — Apple Health (optional, opt-in)

**Goal:** optional, opt-in HealthKit. On-device; never transmitted. Fully functional
when denied. Writes **one** workout per session, on finish — not per set.

**Setup.** HealthKit capability (via `project.yml`) + Info.plist
`NSHealthShareUsageDescription` (read) and `NSHealthUpdateUsageDescription` (write).
Update the README's entitlements line (see §4).

**Read — bodyweight.** Most recent `HKQuantityType(.bodyMass)` for the calorie estimate
(PR 11) and bodyweight-relative PRs. If denied/absent, fall back to a manual Settings
field. Wrap in a `HealthService` protocol so it's mockable and no HealthKit symbol leaks
into code that must compile without the entitlement in tests.

**Write — the workout, not the guess, and only on explicit opt-in.** Writing
`HKWorkout`s is gated behind an explicit in-app Settings toggle ("Save workouts to Apple
Health"), default **off** — system write *permission* is not the same as user *intent*.
Only with the toggle on *and* permission granted, write **one** `HKWorkout` of
`.traditionalStrengthTraining` when a **session finishes** (PR 3), using the session's
`started_at`/`ended_at` bounds — not one workout per saved set. **Do not** write the
rough calorie estimate as `activeEnergyBurned` into the Move ring — a guessed number
polluting health data is what App Review flags. Keep the estimate in-app.

**Rules.** Privacy policy required (PR 1); HealthKit data must not be used for ads or
written to iCloud.

**Acceptance:** denied → behavior unchanged; the toggle defaults off and **no** workouts
are written until it's explicitly on; with toggle on + permission granted, finishing a
session writes exactly **one** strength `HKWorkout` spanning the session, visible in the
Fitness app; no estimated energy written anywhere.

**Tests (fake `HealthService`):** finishing a session triggers exactly one workout write
when enabled, zero when the toggle is off or permission denied; bodyweight read falls
back to the manual field when unavailable.

---

## PR 11 — Calorie estimate (session-bounds precedence)

**Goal:** a clearly-rough per-session kcal estimate. Deterministic; AI never touches it;
honest framing.

- **Duration precedence:** explicit `ended_at − started_at` (set at finish or via PR 4 `updateSession`) → else first/last set `created_at` span → else a manual duration the user entered → else show "Add a duration to estimate calories." Clamp degenerate cases (single set with no end → small fixed estimate; absurd gaps → cap). **Never invent.**
- **Bodyweight:** from PR 10 (HealthKit) or the manual Settings field. If missing, show "Add your bodyweight to estimate calories" — never invent a number.
- **Formula:** `kcal ≈ MET × bodyweight_kg × duration_hours`. MET is a typed `AnalyticsPolicy`-style knob (default ~5.0), not a magic constant.
- **UI:** History session header/detail shows "~X kcal (estimate)". Never precise.

**Acceptance:** estimate uses the explicit session bounds when present, the set-span when
not, and the manual duration as last resort; matches the formula on a fixture; absent
bodyweight or duration shows the prompt, not a zero/fake.

**Tests:** duration precedence (explicit bounds > set span > manual > prompt); calorie
formula; single-set and large-gap clamps.

---

## PR 12 — Home Screen widget (current / last workout)

**Goal:** a read-only WidgetKit widget on the shared store, plus quick entry. Depends on
PR 1 and the session model (PR 3).

- New widget-extension target (via `project.yml`), same App Group; opens its **own read connection** to the shared SQLite file (cross-process WAL reads are safe).
- Move the small read types the widget needs (a widget DTO, or `WorkoutSetHistoryRow` + `WorkoutLoad` + enums + `OpenSession`) into a **Shared** module so both targets compile.
- Content: if a session is open → "Current workout · N sets" (from `currentOpenSession()`); else "Last workout · <name/date> · N sets". Optionally this week's sets/volume; a "quick log" button deep-linking into Today.
- Refresh on a modest cadence + `WidgetCenter.shared.reloadAllTimelines()` after a save/finish. Never writes.

**Acceptance:** shows the current open session's set count while one is active, and the
last finished workout otherwise; updates after a save/finish; quick-log opens Today;
builds against the App Group container.

---

## PR 13 — Import (JSON restore; CSV stretch)

**Goal:** let a user get their data back (reinstall) or bring it from elsewhere. Export
already exists; this is the inverse. Import is still propose-then-confirm at the file
level: parse, preview a summary, then write.

- **JSON round-trip restore (baseline).** Read the app's own export (`schema_version` aware: handle 1 and 2). Match exercises by **`slug`** (create missing customs with `is_custom = 1`); recreate sessions and sets through the normal `WorkoutStore` write path (one transaction per session; `set_index` continuation honored). Safest target is an empty/fresh library; if the library is non-empty, present a clear "merge vs replace" choice and default to a dry-run summary ("will add N sessions, M sets, K new exercises").
- **Idempotency.** Don't double-import: dedupe sessions on (`started_at`, set fingerprint) or skip sessions whose exact contents already exist; show what was skipped.
- **CSV (Strong / Hevy) — flagged stretch.** Map their columns to canonicals via the resolution stack (exact→alias→fuzzy→confirm); unmatched rows go to a review list, never silently created. Keep behind a clearly-labeled "experimental import" path; do not block this PR on CSV.

**Acceptance:** exporting then importing into a fresh library reproduces sessions/sets/
exercises exactly (round-trip), matching exercises by slug; re-importing the same file is
a no-op (idempotent); a non-empty library prompts before writing and can dry-run.

**Tests:** JSON round-trip equality on a fixture (schema_version 2); slug-matching
creates missing customs once; re-import idempotency; malformed file fails cleanly with a
message.

---

## PR 14 — OCR capture (sheet → parse pipeline) — *optional / post-launch candidate*

**Goal:** photograph or import a handwritten/printed workout sheet and turn it into
proposed entries. **OCR is an input source, not a new pipeline** — recognized text feeds
the existing deterministic → fuzzy → LLM → confirm → write path. On-device; nothing
auto-saves. Slot late and treat as optional; it adds a camera-permission + App Review
surface and isn't table-stakes.

- **Recognition (on-device, Apple Vision).** Use Vision text recognition (`VNRecognizeTextRequest` / the document-recognition request, or `DataScannerViewController` for live capture). Gate availability like FM/embeddings; degrade gracefully. Camera + photo-library permission with honest Info.plist usage strings; works from an imported image too (no camera needed).
- **Multi-line → active session.** Each recognized line becomes a candidate entry parsed by the existing stack; all confirmed lines **append to one active session** (PR 3). Present a review list (each line: parsed draft, a low-confidence flag, edit/skip) — **confirm everything before any write.** Never auto-save OCR output.
- **Honesty.** Printed text is reliable; handwriting is not. Frame it as assistive ("review these — OCR can misread"), surface confidence, and make correction trivial. The confirm card is the safety net.

**Acceptance:** importing a clean printed sheet yields a review list of parsed entries
that, on confirm, append to one session; low-confidence/unparseable lines are flagged and
editable, never silently dropped or saved; denying camera still allows image import;
nothing is written without confirmation.

**Tests (fake recognizer feeding known strings):** multi-line text produces N candidate
drafts routed through the same parser; confirmed lines append to one session with
continued `set_index`; an unparseable line is flagged, not saved.

---

## PR 15 — App Store submission readiness (the final gate)

**Goal:** clear App Review on the first attempt. Mostly configuration + honesty, but it's
exactly where privacy-first local apps get bounced.

**Privacy manifest (`PrivacyInfo.xcprivacy`) — an automated *upload* gate.** Declare no
tracking and no collected data types, plus a *required-reason* entry for every
required-reason API touched. At minimum **UserDefaults**
(`NSPrivacyAccessedAPICategoryUserDefaults`, reason `CA92.1`) for plan/timer
persistence; audit the DB/file layer for file-timestamp/disk-space APIs and declare those
if present. Missing/incorrect manifest → rejected at submission.

**App Privacy label: Data Not Collected.** Truthful — no analytics, no third-party SDKs,
no IDFA, no ATT prompt. Accurate *and* a selling point; state it plainly.

**HealthKit (5.1.3), once PR 10 ships:** published privacy-policy URL; honest, specific
usage strings; never use Health data for ads/data-mining; never write Health data to
iCloud; never write inaccurate data (the calorie estimate stays in-app, never
`activeEnergyBurned`); Health write is opt-in in-app, not merely permission-gated.

**Camera (5.1.1), if PR 14 ships:** honest `NSCameraUsageDescription` /
`NSPhotoLibraryUsageDescription`; the app must work without camera access (image import
+ manual entry).

**Reviewer can exercise everything with all permissions denied.** Non-Apple-Intelligence
device, HealthKit/notifications/camera denied → still fully usable: deterministic parser
is the primary path, bodyweight has a manual fallback. Verify end-to-end on a clean
device and document it in the review notes.

**No account = no demo credentials.** Say so in the review notes.

**Metadata honesty.** Don't overclaim "AI" or imply medical/diagnostic capability;
describe on-device parsing and clearly-labeled estimates; carry the "not medical or
coaching advice" line into the app and the listing.

**Local notifications:** request in context (when enabling the rest timer), never at
launch; no promotional notifications.

**Acceptance:** a clean install with HealthKit, notifications, camera, and Apple
Intelligence all unavailable is fully usable (deterministic log → confirm → save →
History → Progress with manual bodyweight); `PrivacyInfo.xcprivacy` present and passes
upload validation; App Privacy = Data Not Collected; review notes document the no-account
and deny-everything-still-works paths.

---

## 4. Cross-cutting (fold in as you touch files)

- **README doctrine update:** the "No special entitlements" line is false once PR 1 / PR 10 / PR 14 land. Reword to: minimal **on-device** entitlements (App Group, HealthKit, optional Camera); still no server, no account, no tracking.
- **Ergonomics (rest timer · last-time · PR detection · plate calc)** — all local, all cheap; fold into the relevant surfaces as you build them, or take as a dedicated pass after PR 5: `SaveResult.achievements` (default `[]`) computed in the save transaction (`.estimatedOneRepMax`, `.weightForReps`, `.maxReps` so bodyweight lifts get a PR moment); "last time" reads the prior session's sets for the resolved exercise; rest timer (Settings default 60/90/120/180s; local notification only if permission granted, prompted lazily); plate calculator (pure function: target + bar + plate set → plates per side).
- **Cached formatters** in History/Progress: one `static ISO8601DateFormatter` for parsing, one `DateFormatter` for display. No per-row allocation.

---

## 5. One-paragraph brief

Build WorkoutChatLog v1.2 — no Watch, no dictation — keeping the doctrine: model
proposes (a draft *or a clarifying question*), app confirms, app writes; on-device SQLite
is the only truth; no server, no account, no tracking. Exercise identity is flat and
canonical (stable `slug`, immutable rowid that `sets` reference, owned/unambiguous
aliases, `family_key` for browsing only) — **aliases collapse, variations stay separate,
families never collapse PRs or charts by default**. Confirmed sets append to **one active
session** (lazy-opened, single-open, stale auto-finished, `set_index` continued from
`MAX+1`) until the user finishes it; sessions can be backdated and have times set
manually. Resolution is layered determinism-first (exact → owned alias → fuzzy →
embeddings → LLM); every layer past alias *proposes*; distinct canonicals are never
merged. Sequential gates: **1** foundation (App Group + shared DB + privacy); **2** schema
reset + exercise identity model + full session schema + rep cap + `@MainActor` writes;
**3** active session lifecycle + annotations + post-fill; **4** History view/delete/edit
(set & session); **5** Progress (canonical-only, primary-muscle rollups, off-day/deload
exclusion); **7** fuzzy + embedding suggestions (family-aware, propose-and-confirm); **8**
Foundation Models draft·clarification·declined (isolated, gated, capped follow-ups); **9**
rename/merge exercises (dedupe, not variation-collapse); **10** optional opt-in HealthKit
(one workout per finished session); **11** calorie estimate (session-bounds precedence);
**12** widget (current/last workout); **13** import (JSON restore, CSV stretch); **14**
optional OCR capture (sheet → existing parse pipeline, confirm-everything); **15** App
Store submission readiness. Mutating store APIs are `@MainActor` so the single-connection
write invariant is compiler-enforced. Existing tests pass at every boundary; add the
tests listed per PR.
