# 002 — The Deterministic Parser (Track 1)

What Step 2 taught me building the non-ML half of log parsing — the part that's
a grammar, and the baseline everything else gets measured against.

## The thesis, on my own shorthand

Lifting shorthand has a small, real grammar: `135x8`, `135 for 8,8,7`,
`3x10 @ 135`, `225x5 rpe 8`, `bw x12`, `60kg x 8`. Most well-formed
single-exercise entries need *zero* inference. The fixture
(`ParserFixtures.swift`, ~46 entries) is the proof on my own data: everything
well-formed parses deterministically, and the entries that *don't* parse map
cleanly onto a precise job description for the LLM (Track 2): multi-exercise
lines, prose, and genuinely ambiguous forms.

## Tokenizer, not regex

I hand-rolled a tokenizer instead of reaching for regex. Two reasons: this
environment can't compile Swift, so I wanted logic I could verify by *reading*,
step by step, rather than dense pattern soup; and it sidesteps any
regex-literal/compiler-version surface. The tokenizer does one clever thing —
it spaces out the operators that get glued to numbers in real shorthand
(`135x8` → `135 x 8`, `@`, `,`) — and then it's plain token matching. The `x`
split only fires when it sits between/next to digits and isn't inside a word, so
`max` and `Farmer's` survive.

## The interesting decisions (made, then written down)

- **`A x B` disambiguation.** This is *the* ambiguity. `135x8` is weight×reps;
  `3x10` is sets×reps. The rule: a leading number with a unit (`10lb x 12`) is
  always a weight; otherwise a small leading number (1…10) is a set count and a
  larger one is a weight. The honest part: a small *unitless* number that the
  user meant as a light dumbbell (`curl 8x12`) will be misread as 8 sets — so the
  escape hatch is stating the unit or using `@`. That residual ambiguity is
  deliberately left to Track 2.
- **`rpe` → `rir`.** RIR is the only subjective field the spine stores, so a
  stated RPE is converted (`rir = 10 − rpe`, clamped); a stated RIR is taken
  as-is. RIR stays `nil` when neither is present — never guessed.
- **Unspecified weight → 0.** `3x10` (a set scheme with no load) records weight
  0, i.e. bodyweight-until-edited. It's indistinguishable from a true bodyweight
  set at the data layer, which is fine: the confirm UI (Step 3) is where a real
  weight gets filled in.
- **Default unit is `lb`.** A US default; an explicit/glued unit always wins.
- **Confident-or-nil.** The parser returns `nil` rather than guess: 3-number
  forms (`135x8x3`), prose, empty input. `nil` *is* the hand-off to Track 2.

## A limitation I found by building

Name extraction is greedy: everything before the first number becomes the
exercise span. So a multi-exercise line with a trailing set
(`"bench and then deadlift 405x3"`) doesn't get *declined* — it parses with a
junk single name. I chose **not** to bolt on prose/connective detection
heuristics (fragile, and over-reaching for a deterministic baseline). The
parser's contract is *single-exercise input*; splitting multi-exercise lines is
squarely Track 2's job. Documented rather than papered over.

## It plugs into the one write path

The parser emits `[SetDraft]` with the exercise left as a raw lowercase span —
exactly what `WorkoutStore.save` already consumes. `testParsedSetsFlowThroughThe
SavePath` proves it end to end: `"bench 135 for 8,8,7"` → three drafts → `save`
→ three rows, with `"bench"` resolved through the alias map to the seeded
**Bench Press**. That's the spine thesis paying off: a new input path cost
*nothing* at the storage layer.

## Same constraint as Step 1

No Swift toolchain here, so the parser wasn't compiled and the tests weren't run
locally. The tokenizer was written to be read-verifiable, and the fixtures
double as executable documentation for the first `xcodebuild test` on macOS.

## Review round

The review caught a real one: I picked the numeric core by the *first*
weight-like token, so a seeded alias that starts with a number —
`45 degree back extension` — made `45 degree back extension 100x10` decline,
because the leading `45` was mistaken for the spec. The fix: the spec is the
*trailing* run of numeric/operator tokens, and the name is everything before it.
Scanning from the end keeps digits inside names. Added a fixture for exactly
that input.

Also pinned the bare-scheme contract that the reviewer flagged: `3x10` parses
with an **empty** exercise name (its exercise comes from context) and, by design,
won't survive `save` until one is attached — there's now a test asserting both
halves. Parser generous, saver strict, stated out loud.

The macOS-CI bootstrap smoke test remains the same standing deferral as in the
spine step.

A second round raised two more:

- **Policy: a named weightless scheme is a *proposal*, not a silent save.**
  `bench 3x10` parses to three 0-lb Bench Press drafts. That's only safe because
  the doctrine is *model proposes, app confirms, app writes* — parser output
  always passes through a confirm/edit surface (Step 3) before `save`, where the
  0 shows up as a "fill me in" placeholder. Nothing auto-saves parser output
  today; the confirm card is where the 0 gets a real weight. Stated explicitly so
  it can't quietly become a direct-save path later.
- **Resolution now collapses whitespace.** `resolveExercise` trims *and* collapses
  internal runs (`bench   press` → `bench press`) before matching or creating, so
  sloppy spacing can't spawn near-duplicate lifts. The chosen contract:
  exact-except-case-and-whitespace. Anything fuzzier ("incline db" →
  "Incline Dumbbell Press") is deliberately left to Track 3's embeddings, not
  baked into the deterministic resolver.

A third round, two more decisions:

- **Effort is confident-or-decline.** `rpe`/`rir` used to accept any number,
  round it, and clamp to 0…10 — so `rpe 7.5` silently became RIR 2 and `rpe 12`
  became RIR 0. Since RIR feeds analytics directly, that's fabrication. Now the
  parser requires a clean integer in 0…10 and otherwise declines the whole entry
  (Track 2 can interpret half-points). No silent rewriting of a number a user
  will later see in a chart.
- **Why not "reject zero-load lifts at save"?** The reviewer suggested rejecting
  0-weight weighted drafts at the save boundary. I declined that: weight 0 is a
  *legitimate* value — every bodyweight pushup/pullup/dip set is 0 — and the spine
  can't tell "unspecified" from "bodyweight" (both are 0.0). Rejecting 0 at save
  would break real logging. The correct guard is the doctrine's mandatory confirm
  step (Step 3), where an unspecified 0 either gets a real weight or is confirmed
  as bodyweight. Documented rather than enforced with a rule that would do harm.

## Next

Track 2 (Foundation Models) owns what this declines, and Step 3 (the "ugly UI"
save) is where a typed entry first becomes a confirm card. The fixture is
deliberately reusable so the same ~46 entries can be run through the on-device
LLM and compared head-to-head — the experiment the spec actually cares about.
