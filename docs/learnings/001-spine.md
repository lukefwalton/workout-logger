# 001 — The Spine

What Step 1 taught me, building the skeleton and the one disciplined data layer.

## Stealing conventions from the political app

`stop-political-spam-texts-ios` is the only other native app in this monorepo,
and it's a clean template. What I adopted:

- **XcodeGen, no committed `.xcodeproj`.** The project is declared in
  `project.yml` and generated. The committed surface is source + a spec, not a
  giant pbxproj that conflicts on every merge. The repo's `.gitignore` already
  ignored the political app's generated project; I added a local `.gitignore`
  for ours.
- **Zero third-party dependencies.** The political app bundles no external code
  and says so. For a privacy/utility app that's a feature, not asceticism — it's
  what lets the "no network, no tracking" claim be auditable. I held the same
  line here, which decided the SQLite question below.
- **Comments explain *why*, not *what*.** Its files read like a doctrine. I tried
  to match that: the comment on `MessageFilterExtension` is a permanent privacy
  contract; my analog is the "honest spine" note on `WorkoutStore`.
- **`@AppStorage`-gated root, explicit `Info.plist` with
  `GENERATE_INFOPLIST_FILE: NO`.** I mirrored the Info.plist shape exactly.

The interesting *difference*: the political app's whole architecture is a shared
classifier behind an App Group, because its hard problem is two processes (app +
extension) agreeing on config. Our hard problem is the opposite — one process,
many *input paths* (chat, quick-log, corrections) that must converge on one
write path. So the keystone here isn't an App Group, it's the `WorkoutDraft`
contract.

## Why XcodeGen

Beyond matching the sibling app: XcodeGen generates the Xcode project from a
folder structure and a small YAML spec, so adding a file is just adding a file —
no manual target membership, no pbxproj merge conflicts. For a project that's
going to sprout a lot of files across many "tracks," that churn reduction is
worth the one-time `brew install xcodegen` cost.

## Why raw SQLite (and not GRDB / SQLite.swift)

Real fork in the road. The ergonomic choice is GRDB or SQLite.swift (both MIT,
both copyable under our rule). I chose the raw `sqlite3` C API anyway:

1. **Zero dependencies** keeps the app's audit story as clean as the political
   app's, and the spec's scavenger discipline explicitly says the local-SQLite
   layer is *our* architecture to own, not something to import.
2. **App-owned SQL** is a hard rule of the spine ("no generated SQL"). Hand-
   writing every statement makes that boundary literal.
3. **Highest learning-per-line.** This is a playground; the C interop *is* part
   of the point.

What the interop actually taught me (the gotchas, now encoded in `SQLiteDB`):

- **`PRAGMA foreign_keys = ON` is mandatory and per-connection.** SQLite ships
  with foreign keys *off* by default, so every `ON DELETE CASCADE` in the schema
  is silently inert until you turn it on. There's a test
  (`testDeletingSessionCascadesToSets`) whose only job is to fail loudly if this
  regresses.
- **`PRAGMA journal_mode = WAL` must run outside a transaction.** So pragmas live
  in `init`, before any `BEGIN`.
- **`SQLITE_TRANSIENT`.** Bound strings must be copied by SQLite, or you hand it
  a pointer into a Swift `String` buffer that's already gone. The
  `unsafeBitCast(-1, ...)` incantation is how you say "copy this."
- **Bind indices are 1-based, column indices 0-based.** The API mixes them; I
  kept that in the wrapper so call sites read like the SQL.
- **Migrations via `PRAGMA user_version`.** Forward-only, each bump inside its
  own transaction. `Schema.migrate` is a ladder of `if userVersion < N`.

## The save-path design

One path, and everything funnels through it:

```
WorkoutDraft → WorkoutValidator.validate → db.transaction { insert session; for each set: resolveOrCreateExercise; insert set } → SaveResult
```

Decisions worth recording:

- **Parser generous, saver strict.** `validate` runs *before* the transaction
  opens, so a bad draft can't even start a write. Bounds are deliberately loose
  (reps 1–100, RIR 0–10, weight ≥ 0 so bodyweight = 0 is legal) — the goal is to
  stop garbage, not to second-guess the user.
- **`resolveOrCreateExercise` is a cascade with a seam.** Today: exact canonical
  (case-insensitive) → alias → create new. The new exercise is created
  *muscle-less* and user-correctable rather than guessed at. Track 3's embedding
  nearest-neighbor slots in as a step between "alias" and "create new" without
  touching the write path — that's the seam working as intended.
- **`SetDraft` vs `StoredSet`.** A draft is a proposal with no database identity;
  a `StoredSet` is a fact with IDs. Keeping them separate types stops "is this
  saved yet?" ambiguity from creeping in.
- **`SaveResult` is shaped for Track 5.** PR/achievement detection will be
  computed inside the same transaction and added to `SaveResult` without
  changing callers — so achievements "ride along" the save flow, as the spec
  wants, but none of that logic exists yet.
- **`AnalyticsPolicy` is a type, not buried in SQL.** "Hard set" is a policy
  (what RIR threshold? does unknown-RIR count?), not a fact. Making it a `Codable`
  struct means the eventual charts read knobs instead of hardcoding a definition
  that would quietly lie when the policy changes.

## The seed and the one correctness surface

The spec calls the muscle map "the one non-negotiable correctness surface" — a
wrong tag rots per-muscle analytics invisibly and forever. So:

- The 89-lift `seed_exercises.json` uses the **public-domain free-exercise-db**
  muscle vocabulary (17 groups). License is the Unlicense, logged in `NOTICE.md`.
- I validated the seed *programmatically* before trusting it: exactly 89 lifts,
  unique canonical names, **globally unique aliases** (an alias must map to
  exactly one lift, or resolution is nondeterministic), every muscle in
  vocabulary, no primary muscle also listed as secondary. The same invariants
  are asserted in `SeedExercisesTests`.

## Loose decisions I deliberately didn't make

- **Epley vs Brzycki for e1RM** — not needed until Track 4 (charts). The spec's
  example SQL uses Epley (`weight * (1 + reps/30)`); I'll likely start there and
  compare, per §13 ("answer by building").
- **Which set types count as working-equivalent / null-RIR-as-hard** — these are
  the `AnalyticsPolicy` defaults; chosen as defaults, not hardcoded, precisely so
  they can change later.

## The honest constraint: I couldn't run this

There is **no Swift/Xcode toolchain in the Linux build environment**, and iOS
builds are macOS-only. So I could not compile the app or execute XCTest here. I:

- wrote the code to idiomatic Swift, mirroring a sibling app that's known to
  build and ship;
- validated everything I *could* validate without Swift — the seed JSON's
  integrity, with a Python script;
- wrote the tests to pass under a real `xcodebuild test` on macOS.

This is flagged plainly in the PR rather than dressed up as green CI. The first
real Xcode run is the actual verification gate for this step.

## Review round 1 (the loop working)

The automated review caught two things worth fixing inside this step:

1. **Fail loud, not blank.** `SettingsView` read the seeded count with `try?`,
   which turned a database read *failure* into `"—"` — indistinguishable from
   "no data." But this tab's whole job is to prove the spine opened and seeded.
   Replaced it with an explicit `loading / loaded / failed` state; a read error
   now shows in red with the message.
2. **The strict saver had a blind spot: the name.** `validate` checked weight,
   reps, and RIR but never `exerciseName`, and `resolveOrCreateExercise` trimmed
   then inserted whatever was left — including `""`. A future parser or quick-log
   submitting whitespace could seed a blank `canonical_name` row and quietly rot
   the registry. Added a `ParseError.emptyExerciseName` guard in *both* the
   validator (the batch gate) and the resolver (the point of insertion, so direct
   callers are covered too), with tests.

The lesson in #2: "saver strict" only means something if it checks the field the
later input paths will actually fill. The name was the easy one to forget
*because no input path produces names yet* — cheap to lock down now, annoying to
discover as junk rows later.

Deferred on purpose: the review also suggested a macOS CI job
(`xcodegen` + `xcodebuild test`). That's genuinely the right fix for "couldn't
compile in this environment," but it's standing infra beyond the step-1 rail and
a cost decision worth making deliberately — flagged as a follow-up rather than
bundled in here. The unit tests already cover the migrate → seed → read
bootstrap at the layer a unit test can reach; the app-bundle packaging itself
still needs a real Xcode build.

## Review round 2

The re-review confirmed round 1's fixes and surfaced two subtler ones:

1. **Label honesty.** Settings said "Seeded exercises" but `exerciseCount()`
   counts the *whole* `exercises` table — and `resolveOrCreateExercise` adds
   user lifts to that same table, so the count would inflate after the first
   custom exercise. The spec (§2.3) intends **one** editable registry where seed
   and user lifts coexist, so the fix is the wording, not a schema split:
   renamed to "Exercises in library." I deliberately did **not** add a
   seed-vs-user provenance column — it's not in the spec schema, nothing needs
   it yet, and it's a cheap migration to add later if a feature ever does.
2. **Enforce the single write path by type, not by comment.**
   `resolveOrCreateExercise` was callable from anywhere in the module, so a
   future feature could mint permanent `exercises` rows outside a save
   transaction — quietly eroding the very invariant this step exists to set.
   Split it: a non-mutating `resolveExercise` (lookup only — exact → alias →
   nil; the safe seam for a confirm-card preview or quick-log) stays internal,
   while the creating `resolveOrCreateExercise` is now **private**, reachable
   only through `save`. Tests assert lookups via `resolveExercise` and verify
   creation by going through `save` — which is the real path anyway.

The theme across both rounds: the spine's value is its invariants, and an
invariant that's only a comment is one a later track will step on. Where the
type system can hold the line (private creation) or the data can (blank-name
rejection, the muscle-vocab tests), let it.

## Review round 3

Converging — no red flags, both round-2 fixes confirmed. Two cheap hardening
fixes and one standing deferral:

1. **Reject non-finite weights.** `weight >= 0` lets `Double.infinity` through
   (`NaN` already failed the comparison). A future parser or model building a
   bad `Double` shouldn't be able to land an impossible weight in SQLite, so the
   guard is now `weight.isFinite, weight >= 0`. Tested both `inf` and `nan`.
2. **Lock the alias/canonical boundary.** Resolution is exact-canonical → alias,
   so an alias that equals a *different* lift's canonical name would be shadowed
   by the exact match and silently resolve to the wrong exercise. The seed
   already avoids this; added a test so it stays that way.
3. **Bootstrap smoke test — deferred a third time, on purpose.** The
   `AppDatabase.makeStore()` + app-bundle `seed_exercises.json` packaging path is
   the one thing the suite can't prove (the storage tests load from the *test*
   bundle), and it genuinely needs a macOS build/CI to exercise. It's the first
   thing to add when macOS CI lands; not fakeable as a unit test here.

## Review round 4

Round-3 fixes confirmed. Two cheap, honest fixes plus one decision captured:

1. **Don't promise what isn't built.** Settings' About copy said "you can export
   all of it," but export is Track 6 and there's no export surface yet. Reworded
   to present-accurate ("your data stays on this phone"); softened the same
   overclaim in the README. Truth-in-UI matters even in a placeholder shell.
2. **Decide the non-rep movements early.** The seed includes time-based holds
   (Plank) and loaded carries (Farmer's Walk), but the spine models a set as
   weight × integer reps. Decision, captured now in a `Schema.swift` note rather
   than silently baked in: v1 stays weight×reps; a duration/measure dimension is
   a deliberate later extension, and the parser/quick-log step is where the
   logging convention for holds/carries gets settled. I did **not** add a measure
   dimension (out of step-1 scope) or drop the curated movements.

Bootstrap smoke test deferred a fourth time — same reasoning; it lands with
macOS CI.

## Review round 5 — and calling Step 1 done

One new polish item: the UI rendered `String(describing: error)` raw (startup +
Settings). That's the flip side of round 1 — *surface* the failure, but with a
stable human message, not a raw SQLite string as the headline. Now both spots
lead with a plain-language message and demote the raw error to a small secondary
line (kept for bring-up/debugging). Fail loud, but legibly.

At this point I'm calling Step 1 **confident**. The review converged: the round-1
red flag and every actionable yellow are fixed, and rounds 4–5 were polish and
repeats. Two items remain open *by decision*, both documented:

- **macOS-CI bootstrap smoke test** — needs a real build to exercise the
  app-bundle resource path; lands when macOS CI does.
- **Duration/measure dimension** for holds/carries — the spine stays weight×reps
  for v1; the parser/quick-log step settles the convention.

Chasing every remaining nitpick would fight the step-by-step discipline this
build is built on. The spine is honest and well-tested; time to build on it.

## Review round 6 — final spine hardening

Round-5 fix confirmed. Two last changes, both completing invariants this step is
about:

1. **`WorkoutStore.db` is now private.** It was internal, so feature code could
   have grabbed the raw connection and run ad hoc SQL around validation — the
   exact bypass the single-write-path rule forbids. Making it private finishes
   the job round 2 started (private `resolveOrCreateExercise`). A thin
   `schemaVersion()` seam covers the migration test, and the low-level
   transaction-rollback and FK-cascade tests moved to a new `SQLiteDBTests`,
   exercised against `SQLiteDB` + `Schema` directly — the right altitude, since
   those are connection/schema guarantees, not domain-store ones.
2. **Debug-gated raw error strings.** Startup and Settings failure detail is now
   `#if DEBUG`, so release users see only the stable message while devs keep the
   raw diagnostics. The reconciliation of rounds 1→5→6: surface that it failed
   (always), show a human message (always), expose the raw cause (debug only).

That closes Step 1. The remaining review items are unchanged documented
deferrals — the macOS-CI bootstrap smoke test (needs a real build) and a
duration/measure dimension for holds/carries (settled at the parser step). The
spine is honest, encapsulated, and well-tested. On to Track 1.

## A note on the Python CI suite

The repo's `Test` job (`pytest -m ci`) failed on this branch. It is **not** from
this PR: the change is additive and Swift-only, touches no Python, modifies no
existing file, and the `testpaths` (`tests/`, `impact-analysis/tests/`) and
`conftest.py` (which registers specific named dirs, not arbitrary ones) are
untouched — so it collects the identical suite it would on `main`. `Lint`
(`compileall .` over the whole repo) and `Build` pass, confirming the new files
don't break Python tooling, and the failure reproduced across multiple commits
(consistent, not flaky). It's a pre-existing/unrelated failure in the monorepo's
Python tests; fixing it is out of scope for a Swift-only PR and isn't attempted
here.

## What's intentionally absent (the rail)

No Foundation Models, no embeddings, no charts, no export, no quick-log, no
parser, no achievement logic, no cloud. Each is its own later step. Step 1 is
just: a buildable native shell, and a spine honest enough that everything built
on top of it can be trusted.
