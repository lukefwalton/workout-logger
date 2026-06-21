# 013 — Foundation Models: draft · clarification · declined (v1.2 PR 8)

The marquee feature, and the highest compile-risk PR in the plan: when the
deterministic grammar returns nil, the on-device LLM gets **one shot** to produce
a draft proposal or ask a short clarifying question — never to write. Built here as
an FM-free core with a fake-driven test suite (fully doable on Linux) plus a
totally-isolated, gated real parser (correct-by-inspection; symbols to be verified
in Xcode).

## Total module isolation is the whole game

Not one `FoundationModels` symbol appears in always-compiled code. The split:

- **Common (Foundation only):** `ParseOutcome` (`.draft`/`.clarification`/`.declined`),
  `WorkoutParseResult` (flat `[SetDraft]` + a `ParseSource`), `ClarificationPrompt`,
  the `WorkoutParsing` protocol, the `WorkoutParserOrchestrator`, the
  `DeterministicWorkoutParsing` adapter, and — crucially — `ModelDraftMapping`, the
  *defensive* translation logic.
- **Gated (`#if canImport(FoundationModels)`):** `FoundationWorkoutParser`, the
  `@Generable`/`@Guide` response types, and `isModelAvailable()` over
  `SystemLanguageModel.default.availability`. The whole file is one `#if`.

The orchestrator holds the FM layer as a plain `WorkoutParsing?` — nil when the SDK
is absent at compile time *or* the model is unavailable at runtime. So the type that
decides ordering never names an FM symbol, and tests drive it with a fake. The
`WorkoutParserFactory` is where the two worlds meet: a `#if`/`#else` pair where only
the `#if` branch constructs `FoundationWorkoutParser`, behind both
`#available(iOS 26.0, *)` and the runtime availability check.

## The defensive mapping lives in common code on purpose

The part most likely to harbor a bug is the translation of a model's free-form
output into canonical types — unknown enums, out-of-range reps/RIR, a stated-but-
unreadable unit. So `FoundationWorkoutParser` pulls plain `String`/`Int`/`Double?`
fields off its `@Generable` response and hands them to `ModelDraftMapping`, which is
Foundation-only and **unit-tested here**. The governing rule is **all-or-nothing**:
if any single set is unreadable, the whole entry declines rather than silently
dropping a set (honest data over partial data). One normalization, not invention:
an `external` load with weight 0 becomes `unspecified` — the same rule the confirm
card already applies — instead of a fabricated "0 lb."

## The clarification loop is a capped state machine

`TodayModel.Status` gains `needsClarification(ClarificationPrompt)`. On a
clarification the model preserves the **original** entry; tapping a suggested reply
re-invokes `parse(originalInput, context: [replies…])` with the chosen reply
appended. The round cap is 2: I count clarifications *shown* (incremented when a
`.clarification` outcome is applied), and on the 3rd would-be question decline with
"type it manually." Prototyped the counter in Python first (initial question = round
1, one follow-up = round 2, next reply → declined) before porting, then asserted the
exact sequence with a fake that always asks. "Type it manually" is a separate hatch
that clears the loop and keeps the typed text; a fresh `parse()` always resets the
round state so a new entry can't inherit a stale counter.

## Parsing went async — threaded through carefully

The FM layer awaits the on-device model, so `WorkoutParsing.parse` is `async` and
`TodayModel.parse()` followed. The deterministic path satisfies `async` trivially.
The view's button/`onSubmit` actions hop onto a `Task`; the model still publishes
all its state on the main actor. Every existing `TodayModelTests` call site became
`await model.parse()` (the test class was already `@MainActor`), which is the bulk
of the diff's churn but mechanical.

## Doctrine held end-to-end

The FM layer **proposes**; it never writes. An FM `.draft` flows through the *same*
confirm card, `WorkoutStore.save`, and `WorkoutValidator` as any other draft — no
second validator — and surfaces the PR-7 "did you mean…?" suggestions for a proposed
new lift. A new test proves nothing persists until confirm: a clarification writes
nothing, an FM draft writes nothing, only `save()` writes. The confirm card shows a
"parsed with Apple Intelligence" note keyed off `ParseSource`, so the user always
knows when a draft came from the model.

## A real read, validated for real

The FM prompt needs the user's known lifts, so I added a non-isolated
`WorkoutStore.exerciseNames(limit:)` — most-used first (so the cap keeps the relevant
ones), LEFT JOIN so unused seeded lifts still appear. Validated the SQL in sqlite3
against the v1 schema (ordering, the limit, zero-use rows) before porting, and added
a store test.

## Not compiled here — and what that defers

No FoundationModels SDK on Linux, so the gated parser is correct-by-inspection. The
symbol names and the `iOS 26.0` floor quoted in the spec are *illustrative* —
`LanguageModelSession(instructions:)`, `respond(to:generating:)`, `@Generable`,
`SystemLanguageModel.default.availability`, the `Response.content` accessor — and
**must be verified against the installed SDK in Xcode**, where the SDK is the source
of truth. Everything FM-free (orchestrator ordering, the mapping, the clarification
state machine, the new read) is unit-tested; the on-device LLM behavior is a
human-on-device acceptance step. The optional commentary→annotation bridge (spec
calls it explicitly non-blocking) is deferred to keep this compile-risky PR tight.

## Review round

The bot caught the two real risks of going async, both fixed:

- **🔴 The FM `catch` was indistinguishable from a legitimate decline.** A wrong SDK
  symbol or decode mismatch would have looked exactly like the user typing prose.
  Added a DEBUG-only diagnostic that logs the *error* (never the user's input, so no
  PII) before returning `.declined` — the user-facing behavior is unchanged, but an
  integration regression is now visible while validating on-device.
- **🟡 Stale async results could apply out of order.** Two fast submits (or repeated
  clarification-reply taps) could have an older, slower FM call resolve *after* a
  newer one and clobber `pending`/`status`. Added a monotonic `parseGeneration`
  token: `runParse` claims the next token and, on resume, applies its result only if
  it's still the latest. Mutated/read on the main actor, so the check is race-free. A
  continuation-gated `GatedFakeParser` actor lets a test complete two overlapping
  parses out of order and assert the stale one is dropped.

On the bot's question — the one-time `exerciseNames(limit:)` snapshot in
`WorkoutParserFactory.foundationLayer` is **intentional**. The FM parser runs *off*
the main actor, so it must not touch the live, single-connection store; snapshotting
the names once on the main actor at construction is the thread-safe choice. The list
is only a *hint* to prefer existing canonicals — a just-created exercise is still
fully parseable, and identity resolution still happens through the store (PR 7) after
the draft. Refreshing the hint after every save would mean either an unsafe off-main
store read or rebuilding the parser each save; not worth it for a hint.

A second round found the gap the generation token *didn't* close: it dropped stale
results only when a **newer parse** started, but an explicit exit
(`typeItManually`/`discard`) left an already-in-flight reply able to resume and
*resurrect* the dismissed clarification/draft. Fix: those exits now bump the token
too (`invalidateInFlightParse`), so any in-flight parse is stale on resume. Also
added an `isParsing` flag that disables the reply chips and parse buttons while a
parse is awaiting — so quick taps can't accumulate contradictory replies into one
context — while keeping "Type it manually" always live (it cancels the in-flight
parse). A continuation-gated test taps a reply, bails mid-flight, then resolves the
stale reply and asserts the dismissed state holds.
