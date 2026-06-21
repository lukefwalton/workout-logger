# 023 — Layer-3 embeddings (semantic resolution)

Part 2 of the leg, the spec's "PR 7" Layer-3 rung: on-device `NLContextualEmbedding`
semantic matching between fuzzy-low-confidence and Foundation Models. **Landed behind the
gate** as a tidy, fully fake-tested increment — but the real ML path is device-only and
**unverified here**.

## Decision: build the testable scaffold, gate the real model

The spec is explicit: *"Fuzzy (Layer 2) alone is the shippable bar; embeddings (Layer 3)
are opportunistic — do not block on them."* The off-ramp said to ship Part 1 alone if
embeddings became more than a tidy increment. They didn't: the seam already existed
(`ExerciseSuggestion.via = .semantic`), and the **pure** pieces (protocol, cosine,
mean-pool, the suggester, the fuzzy→semantic escalation) are Foundation-only and
unit-testable here. Only the real `NLContextualEmbedding`/`vDSP` path is unverifiable, and
that lives entirely behind the gate. So this landed — with the ML behavior honestly flagged
as a human-on-device acceptance step.

## What shipped

- **`Model/ExerciseEmbedding.swift`** — `protocol ExerciseEmbedding` (Foundation-only) +
  `NoopEmbedding` + `ExerciseEmbeddingFactory`, mirroring the `HealthService` /
  `WorkoutParsing` gating template. Plus `EmbeddingMath` (cosine + mean-pool), pure and
  tested.
- **`Model/NLContextualEmbeddingExerciseMatcher.swift`** — the real matcher, entirely
  inside `#if canImport(NaturalLanguage)` + an `@available` + a runtime asset-load check
  (`hasAvailableAssets` / `load()` / `requestAssets`), so no `NaturalLanguage` symbol
  reaches always-compiled code. Mean-pools per-token vectors; any failure → nil → fall
  through. **Symbol names / OS floor are illustrative — verify in Xcode.**
- **`Model/SemanticSuggester.swift`** — pure ranking: embed the query, cosine-rank cached
  canonical vectors, keep ≥ 0.80, return `ExerciseSuggestion`s with `via: .semantic`.
- **Wiring** (`WorkoutStore.exerciseCanonicals` + `TodayModel`): consulted **only** when
  Layer 2's best is below `semanticEscalationThreshold` (0.85); results **union** with
  fuzzy (fuzzy first, semantic adds new canonicals, never displaces), through the **same**
  "Did you mean…?" confirm path. Canonical vectors are embedded once and cached in memory.

## Doctrine held

- **Proposes; never auto-applies; never merges two canonicals** (§1.1) — semantic
  candidates flow through the identical confirm UI as fuzzy; the user still taps.
- **Opportunistic / never blocks**: `NoopEmbedding` is the default until real embeddings
  load (simulator/ineligible device/assets-not-downloaded all → not ready), so the shipped
  behavior is exactly the fuzzy path. The whole fuzzy suite passes with embeddings
  unavailable.
- **No SDK symbol in always-compiled code**; the gated file is the only place
  `NaturalLanguage` appears.

## Validation (pure logic here; real model NOT verified — Linux, no Xcode/NaturalLanguage)

- **Cosine ranking prototyped in Python**; mean-pool + cosine + threshold all checked.
- **Tests** (fake `ExerciseEmbedding`, no `NaturalLanguage` import): `SemanticSuggesterTests`
  (cosine/mean-pool edge cases incl. zero-vector and ragged/length-mismatch → 0/nil;
  near-miss surfaces a `.semantic` suggestion; not-ready/no-vector → empty; ranking ordered
  + capped) and `TodayModelTests` (a semantic near-miss "thoracic hinge" that fuzzy ranks
  ~0.73 surfaces Deadlift via `.semantic`; the fuzzy suite is unaffected with `NoopEmbedding`).
  Fuzzy/semantic thresholds verified in Python against the metric.
- **The real `NLContextualEmbedding` behavior — asset download, simulator failure, actual
  vector quality, `vDSP` interop — is a human-on-device acceptance step. Not claimed
  working.** If on-device verification finds the symbol names or asset API differ from the
  spec's illustrative names, only the single gated file changes.

## Review round (later) — cache staleness

🟡: `semanticCandidateCache` was filled once and never invalidated, so Layer 3 could freeze
stale — stuck empty if the first lookup ran before assets loaded, and blind to lifts created
mid-session. Two fixes: (1) when the embedding isn't ready, return `[]` **without caching**,
so a later run (assets finished) still builds the cache; (2) `invalidateSemanticCache()`
after a save, since a save can create a new canonical. Added a TodayModel test proving a
custom lift saved mid-session is then reachable by a semantic near-miss (cache rebuilt).
(Late asset-availability mid-keystroke isn't separately invalidated — the not-ready→no-cache
rule already covers the common "assets arrive between lookups" case; a readiness observer is
a possible later refinement, noted.)

## Review round (later) — non-latched readiness

🟡: `NLContextualEmbeddingExerciseMatcher` cached `ready` once at init, so if assets were
missing it stayed `isReady == false` for its whole lifetime — Layer 3 never activated
mid-session even after `requestAssets` finished. Now readiness is **not latched**: an
idempotent `ensureLoaded()` re-checks `hasAvailableAssets` and re-attempts `load()` on each
`isReady` / `vector(for:)` call (requesting assets once), so the matcher flips to ready
later in the same session once the download completes — no view/model recreation needed.
Combined with the TodayModel "don't cache an empty candidate list while not-ready" rule,
Layer 3 turns on on the next lookup after assets arrive. (Still device-only / unverified
here; the fake drives the tested paths.)
