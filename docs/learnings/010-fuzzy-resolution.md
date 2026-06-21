# 010 — Layered Exercise Resolution: Fuzzy (v1.2 PR 7)

When exact + owned-alias both miss, *propose* the right existing canonical
instead of silently creating a near-duplicate. Layer 2 (deterministic fuzzy) is
the shippable bar; Layer 3 (embeddings) is opportunistic and deferred (below).

## The metric, validated before it was ported

`FuzzyMatch.similarity` = `max(jaroWinkler(whole), tokenAverage)`. Jaro-Winkler
catches short typos ("bnch"→"bench"); the per-query-token average catches
multi-word names and a short query hitting one word of a longer name
("dops"→the "dip" in "Chest Dip"). I prototyped the whole thing in Python against
the real seed first — the one part of this PR I *can* actually run here — and
tuned it there, then ported the algorithm faithfully to Swift.

## Threshold and tie-break are calibrated to outcomes

The spec quotes a 0.70 threshold, but that assumes a particular metric; against
this Jaro-Winkler+token metric, 0.70 lets garbage through ("asdfqwer" scored
~0.71). So the threshold is **0.78**, calibrated empirically to the spec's actual
acceptance: real typos surface ("dops"→Dip ≈ 0.85) and garbage returns nothing
("asdfqwer", "qwertyuiop" → []). Ties break by closest name length, so
"bnch press" ranks **Bench Press** first, not the equally-token-matched
"Incline Bench Press".

## The guardrail is the ordering, not the matcher

`suggestExercisesFuzzy` is consulted only when `resolveExercise` (exact → owned
alias) returns nil. So an aliased lift like "rdl" resolves directly to Romanian
Deadlift and never reaches fuzzy — it can't be "corrected" onto Deadlift
(different muscles; collapsing them would corrupt per-muscle analytics). And
because owned aliases are unambiguous, a bare ambiguous term ("dip", "row") has
no alias to hit, correctly falls through, and the user picks among the family's
canonicals. The suggester *proposes*; it never auto-applies and never merges two
canonicals. `familyKey` rides along so the UI can group variants for the choice.

## Confirm UX

When a save would create a new exercise, `TodayModel` fills `pendingSuggestions`
(only then — never when the name already resolves) and the confirm card shows
"Did you mean …?" chips above the new-exercise notice. Tapping one renames the
pending set to that canonical, which then resolves exactly and clears the notice.
Declining still creates the new custom canonical (with a generated slug).

## Layer 3 (embeddings) — deliberately deferred

`NLContextualEmbedding` is opportunistic and the spec is explicit: "Fuzzy alone
is the shippable bar; do not block this PR on embeddings." It can't load in the
simulator, needs a runtime availability gate, and can't be validated in this
Linux environment at all — so rather than ship dead, unverifiable code, it's
deferred to a device-capable follow-up. The seam is ready: `ExerciseSuggestion`
already carries a `via: .semantic` case for when it lands, and the suggester
returns `.fuzzy` candidates today.

## Not compiled here

The fuzzy math is unit-tested (Jaro-Winkler basics, typo/token generosity) and
the store-level behavior is tested against the seed (dops→dip, bnch press→Bench
Press first, bare dip→multiple, garbage→none, rdl→direct). The algorithm was
cross-checked in Python; the SwiftUI chips need a device pass.
