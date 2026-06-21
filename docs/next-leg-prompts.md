# WorkoutChatLog v1.2 — Next-Leg Prompts (handoff)

You're continuing a phased build. **8 of 13 active phases are done** (PRs 1, 2, 3,
4, 5, 7, 9, 13) on branch `claude/charming-allen-VpgPH` → PR
[#220](https://github.com/lukefwalton/scout-tasks/pull/220). Remaining: **8, 10,
11, 12, 14, 15**. Build the lowest-numbered unbuilt phase next.

Below: a **shared onboarding block** (paste/internalize once), then a **focused
prompt per remaining phase**. Hand the onboarding + one phase prompt to the agent.

---

## 0) Shared onboarding — read before any phase

**The spec is law.** `docs/workout-log-build-plan-v1.2.md`.
Before a phase, read §0 (how to work it), §1 (doctrine), §1.1 (identity +
resolution stack), §2 (canonical types), and that PR's section in full. If the
spec and anything else disagree, the spec wins.

**Prior decisions are documented.** `docs/learnings/005–012`
capture every choice + gotcha from phases 1–13. Read the ones adjacent to your
phase (e.g. 006 schema/identity, 007 sessions, 010 fuzzy, 012 import).

**You cannot compile here** (Linux container, no Xcode/simulator). So:
- The repo CI is **Python-only** — it does **not** build the iOS target. The
  recurring **"Test" job failure is a pre-existing repo Python failure, unrelated
  to this app — ignore it.** Your relevant green checks are Lint, Build (Python
  import), the "Config guardrails" job, and Surmado.
- **Validate what you can, for real:** extract the `v1` SQL literal from
  `Schema.swift` and run it through `sqlite3` (`python3` + `executescript`) to
  prove schema/constraints/migrations; prototype algorithms in Python before
  porting to Swift (I did this for the fuzzy matcher and every SQL change).
- Write the spec's XCTest tests as deliverables, but **never claim tests pass** —
  say "not compiled here; correct-by-inspection + sqlite3/Python validation."

**Review loop.** Each push, the `surmado-code-review[bot]` **edits one comment**
(tracked by a `sha:` marker). 🔴 red = fix before merge; 🟡 yellow = fix if
actionable, else justify. Fix → push → it re-reviews → once edits are
trivial/non-relevant, move on. **It is currently rate-limited** — top off at
app.surmado.com/credits for AI review; without credits only deterministic checks
(secrets/model strings) run. Be frugal replying to the bot (it doesn't read
replies); answer the human's "Questions for the author" in your commit/PR text.

**Git.** Develop on `claude/charming-allen-VpgPH`; push there (`-u origin …`, retry
on network errors). One accumulating PR → `main` (the repo's established pattern,
cf. PR #217). The user is fine splitting PRs ~every 4k LOC, but CI + the bot only
run on PRs **into `main`**, so coordinate merge timing with them. End commit
messages with the session URL line; **do not** put model identifiers in commits.
Do **not** open a PR unless asked (PR #220 already exists).

**Architecture contracts to respect (don't relitigate):**
- **`WorkoutStore` is the one write path.** Every *mutating* API is `@MainActor`
  + `try db.transaction { … }`; **reads stay non-isolated** (the widget's process
  must compile). Never mark the whole store `@MainActor`. No feature code runs ad
  hoc SQL.
- **`Schema`**: clean v1 (`latestVersion = 1`); `idx_one_open_session` enforces
  single-open at the DB level; CHECKs on load_kind/reps/rir/unit/set_type; weight
  nullable (`WorkoutLoad.storedColumns` writes canonical NULL for loadless sets —
  `loadKind` is the source of truth). `migrate()` rejects pre-v1.2 local DBs with
  a clear reset error.
- **Identity (§1.1):** `exercises(id rowid = immutable identity, slug UNIQUE =
  stable key, canonical_name mutable, family_key browsing-only, is_custom)`;
  `exercise_aliases(alias PK → exercise_id, ON DELETE CASCADE)`. Resolution order:
  exact → owned alias → fuzzy (`suggestExercisesFuzzy`, PR 7) → **FM (PR 8)**.
  Every layer ≥ fuzzy **proposes**; the user confirms; distinct canonicals are
  **never** merged automatically.
- **Sessions:** lazy-open on first saved set; single open; `save(_:into:)` adopts
  the open session; `TodayModel.reconcileActiveSession(now:)` auto-finishes stale
  ones (different local day / >6h) and returns `false` if it detected a stale one
  it couldn't close (then `save()` refuses, to avoid cross-day merges).
- **Models:** `TodayModel`/`HistoryModel`/`ProgressModel` are `@MainActor`
  `ObservableObject`s; cached `ISO8601DateFormatter`/`DateFormatter` in History/
  Progress. **Test classes that drive writes must be `@MainActor`.**
- **Export/import:** `schema_version = 2`; `ExportedExercise` carries `slug`;
  import matches by slug, restores **closed** historical sessions, is idempotent.

**Doctrine (never violate):** model proposes → app confirms → app writes; on-device
SQLite is the only truth; no account/server/tracking; honest data (never fabricate
reps/RIR/calories/exercise identity); no medical/coaching/diagnostic claims; HealthKit
& Camera opt-in, app fully functional when denied; never write an estimated calorie
value into HealthKit energy.

**Device/SDK gotcha (critical for 8/10/12/14):** anything needing a framework that
isn't in this environment (`FoundationModels`, `HealthKit`, `Vision`, `WidgetKit`)
must be **gated at compile (`#if canImport(...)`) + runtime (availability check)**,
with **no SDK symbol in always-compiled code**; tests drive a **protocol with a
fake**. **Verify exact SDK symbols/OS floors in Xcode — the API names quoted in the
spec are illustrative; the installed SDK is the source of truth.** The real
device behavior (signed App Group container, HK writes, widget render, OCR) is a
**human-on-device acceptance step** — implement to spec, flag clearly.

---

## PR 8 — Foundation Models: draft · clarification · declined  (next; depends on 7 ✓)

> Spec §"PR 8". The marquee feature: when `DeterministicParser.parse` returns nil,
> the on-device LLM gets **one shot** to produce a **draft proposal** or a **short
> clarification question** — never to write. No write power: it proposes/asks; the
> user confirms.

Build the **common, FM-free core + a fake-driven test suite** (fully doable here),
and the **gated real parser** (correct-by-inspection, verify symbols in Xcode):

- **Common code (Foundation only, no FM symbols):** `enum ParseOutcome {
  case draft(WorkoutParseResult); case clarification(ClarificationPrompt); case
  declined }`, `ClarificationPrompt(message <12 words, suggestedReplies ≤3)`,
  `protocol WorkoutParsing { func parse(_ input:String, context:[String]) async ->
  ParseOutcome }`, and the **orchestrator**: deterministic parse → if `.declined`
  and FM available, FM → else `.declined`. The deterministic path returns
  `.draft`/`.declined` only (never asks).
- **Gated code (`#if canImport(FoundationModels)`):** `FoundationWorkoutParser`,
  the `@Generable`/`@Guide` response types (see spec for the shape), and
  `isModelAvailable()` via `SystemLanguageModel.default.availability`. Defensive
  mapping → `ParseOutcome` (all-or-nothing: any unreadable set → `.declined`, never
  silently drop). Map to the **flat** `SetDraft`.
- **`TodayModel`:** add `Status.needsClarification(ClarificationPrompt)`; tapping a
  suggested reply re-invokes `parse(originalInput, context:[previousReplies…])`;
  **round cap = 2** → then `.declined` + "Type it manually". Any FM `.draft` still
  flows through the confirm card + `WorkoutStore.save(_:into:)` + `WorkoutValidator`
  (no second validator). Parsing becomes `async` — thread it through carefully.
- **UI:** clarification question + ≤3 reply buttons + always a "Type it manually"
  button; confirm card shows a "parsed with Apple Intelligence" note and the PR-7
  new-exercise suggestions.

**Acceptance/tests (fake `WorkoutParsing`, no FM import in tests):** builds with FM
unavailable; deterministic wins for "bench 135x8"; no-AI device → unparseable →
`.declined`, no crash; "did chest thing with 45s for a few" → clarification ≤3
replies; reply → draft or one more clarification, capped at 2; mixed valid/invalid
sets decline wholesale; nothing persists before confirm.

**Gotchas:** highest compile-risk PR — keep FM **totally** isolated; the async
ripple touches `TodayModel`/`TodayView`; verify `@Generable`/`SystemLanguageModel`
symbols in Xcode.

---

## PR 10 — Apple Health (optional, opt-in)  (depends on 1 ✓, 3 ✓)

> Spec §"PR 10". On-device, never transmitted, fully functional when denied. Write
> **one** `HKWorkout` per **finished session** (not per set), only with an explicit
> in-app toggle **and** permission.

- Wrap everything in a `protocol HealthService` (read bodyweight `HKQuantityType(.bodyMass)`;
  write one `.traditionalStrengthTraining` `HKWorkout` over the session's
  `started_at`/`ended_at`) so **no HealthKit symbol leaks into code that must
  compile/test without the entitlement**. Tests use a fake `HealthService`.
- `project.yml`: HealthKit capability; Info.plist `NSHealthShareUsageDescription`
  + `NSHealthUpdateUsageDescription`. Update README entitlements line.
- Settings toggle "Save workouts to Apple Health", **default off** (system
  permission ≠ user intent). Write only on `finishSession` (hook PR 3's finish),
  toggle on + permission granted. **Never** write the calorie estimate as
  `activeEnergyBurned`.
- Bodyweight read feeds PR 11; fall back to a manual Settings field when denied.

**Tests (fake `HealthService`):** finishing writes exactly one workout when enabled,
zero when off or denied; bodyweight read falls back to manual when unavailable.
**Device acceptance:** real signed build, Fitness app shows one strength workout
spanning the session, no estimated energy written.

---

## PR 11 — Calorie estimate (session-bounds precedence)  (depends on 3 ✓, 10)

> Spec §"PR 11". A clearly-rough per-session kcal estimate. Deterministic; AI never
> touches it; honest framing. **Fully doable here** (manual-bodyweight path); HK
> bodyweight comes from PR 10.

- **Duration precedence:** explicit `ended_at − started_at` → else first/last set
  `created_at` span → else a manual duration → else "Add a duration to estimate
  calories." Clamp degenerate cases. **Never invent.**
- **Bodyweight:** PR 10 (HealthKit) or the manual Settings field; if missing, show
  "Add your bodyweight to estimate calories" — never a fake number.
- **Formula:** `kcal ≈ MET × bodyweight_kg × duration_hours`, MET a typed
  `AnalyticsPolicy`-style knob (~5.0), not a magic constant.
- **UI:** History session header/detail shows "~X kcal (estimate)". Never precise.

**Tests:** duration precedence (explicit > set-span > manual > prompt); formula on
a fixture; single-set + large-gap clamps. (All pure/deterministic — testable here.)

---

## PR 12 — Home Screen widget (current / last workout)  (depends on 1 ✓, 3 ✓)

> Spec §"PR 12". A **read-only** WidgetKit widget on the shared store.

- New widget-extension target in `project.yml`, **same App Group**
  (`group.com.lukewalton.workoutchatlog`); opens its **own read connection** to the
  shared SQLite file (cross-process WAL reads are safe — already set).
- Move the small read types the widget needs (a widget DTO, or
  `WorkoutSetHistoryRow`/`WorkoutLoad`/enums/`OpenSession` + the non-isolated reads)
  into a **Shared** module so both targets compile. **Reads are already
  non-isolated** — keep it that way.
- Content: open session → "Current workout · N sets" (`currentOpenSession()`); else
  "Last workout · <name/date> · N sets". `WidgetCenter.shared.reloadAllTimelines()`
  after save/finish. **Never writes.**

**Gotcha:** this is why store reads are non-isolated — don't break that. Mostly an
Xcode target-wiring + on-device task; flag the build/render as human-on-device.

---

## PR 14 — OCR capture (sheet → parse pipeline)  *(optional/post-launch; depends on 8)*

> Spec §"PR 14". Photograph/import a workout sheet → proposed entries. **OCR is an
> input source, not a new pipeline** — recognized text feeds the existing
> deterministic → fuzzy → LLM → confirm → write path. Nothing auto-saves.

- Apple Vision (`VNRecognizeTextRequest` / `DataScannerViewController`), gated like
  FM/embeddings; Camera + photo-library Info.plist strings; works from an imported
  image without the camera.
- Each recognized line → a candidate entry through the existing parser; confirmed
  lines **append to one active session** (PR 3). Review list per line (parsed
  draft, low-confidence flag, edit/skip) — **confirm everything before any write.**
- Honest framing: printed reliable, handwriting not; surface confidence.

**Tests (fake recognizer feeding known strings):** multi-line → N candidate drafts
through the same parser; confirmed lines append with continued `set_index`;
unparseable line flagged, not saved. **Slot late — it's optional.**

---

## PR 15 — App Store submission readiness  (the final gate; depends on all)

> Spec §"PR 15". Mostly config + honesty; where privacy-first local apps get
> bounced. **Largely doable here** (manifest/docs); final verification is on-device.

- **`PrivacyInfo.xcprivacy`:** declare no tracking, no collected data; required-reason
  entries for every required-reason API touched (at minimum **UserDefaults**
  `NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1`; audit the DB/file
  layer for file-timestamp/disk-space APIs). Missing/incorrect → upload rejected.
- **App Privacy = Data Not Collected** (truthful, and a selling point).
- HealthKit (5.1.3) once PR 10 ships: published privacy-policy URL (host
  `docs/privacy.md`), honest usage strings, no ads/iCloud/inaccurate data.
- Camera (5.1.1) if PR 14 ships: honest strings; works without camera.
- **Reviewer can exercise everything with all permissions denied** (deterministic
  parser is the primary path; manual bodyweight fallback). Document the no-account +
  deny-everything-works paths in review notes. Don't overclaim "AI"; carry the
  "not medical/coaching advice" line.

**Acceptance:** clean install with HealthKit/notifications/camera/Apple-Intelligence
all unavailable is fully usable; manifest passes upload validation; review notes
cover no-account + deny-everything.

---

## Cross-cutting (fold in as you touch files; spec §4)

README "no entitlements" line is already corrected. Ergonomics (rest timer ·
last-time · PR detection · plate calc) are all local/cheap — `SaveResult.achievements`
(default `[]`, computed in the save transaction), "last time" reads the prior
session's sets, rest timer (local notification only with lazily-prompted
permission), plate calculator (pure function). Fold into relevant surfaces or take
as a dedicated pass after the device phases land.
