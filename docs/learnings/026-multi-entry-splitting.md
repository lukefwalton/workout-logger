# 026 — Multi-entry lines: split, confirm, queue (and rep ranges recover)

Round two of the "never fail to ingest" instruction (see 025). Post-launch use
kept hitting the two dead-ends 025 deliberately left in place — multi-exercise
lines and rep ranges — plus one genuine bug: a pasted multi-line log *silently
mis-parsed*. The bar stays the same: the pipeline doesn't need to be perfect,
but it must land somewhere coherent the user can fix, not on a wall.

## What was failing

- `bench 135x8 + curl 30x10` → "One exercise per line, for now" — in a
  single-line input field, so the advice was impossible to follow.
- `bench 135x8\nsquat 225x5` (a paste) → the tokenizer split on space/tab only,
  glued `8\nsquat` into one token, and **confidently parsed one garbled
  exercise** — the exact outcome the decline-on-ambiguity contract exists to
  prevent.
- `bench 135 8-10` → hard dead-end, even though the name and load were readable
  and reps could honestly stay unset.
- `chinups 7+3` → any `+` was diagnosed as multi-exercise, which blocked the
  forgiving recovery that reads `7+3` as a rep list.
- `bench 135x8 bike 20 min` → the cardio branch proposed the bout and silently
  swallowed the bench.

## The shape of the fix

`DeterministicParser`'s grammar is untouched (its decline tests stay the
contract); everything new is layered around it, same as 025.

1. **`EntrySplitter` + a confirm queue.** The confirm card holds exactly one
   exercise by design — every mutator is entry-wide — so multi-exercise support
   is *sequencing*, not a multi-name draft the card would mangle. On a declined
   line, `TodayModel` splits into segments (newline/`;` always; `+`/`,` only
   before a fresh name word; a bare space only after a complete spec, so
   "close grip bench 135x8" never splits). **All-or-nothing:** every segment
   must independently parse, read as cardio, or recover honestly, otherwise
   nothing splits and no lift is silently dropped. The first segment confirms
   now; the rest queue, and each save pops the next into the input box (an
   "Up next" hint on the card says so). Discard bails on the whole line.

2. **Rep ranges recover with reps unset.** `ForgivingParser` now *consumes*
   `8-10` / `8 – 10` / `8 to 10` instead of choking near it — never picking an
   endpoint — so the name, load, and a glued `3x` set count still land on the
   card with reps at `0`, the unset sentinel that keeps Save disabled. The
   guided rep-range card survives only for lines with nothing else honest to
   recover.

3. **Tokenizers split on all whitespace** (both parsers), which turns the
   silent multi-line mis-parse into a clean decline → split. And the
   multi-exercise diagnosis only fires on `+` before a letter, so `7+3` falls
   through to recovery (the forgiving tokenizer now treats `+` like `,` in rep
   lists).

4. **Split before cardio in the decline path**, so mixed lines become a
   strength confirm plus a queued bout instead of cardio eating the lift.

## Doctrine check

The parser still only proposes; the user confirms each segment on the same
single-exercise card; `WorkoutStore` remains the only writer. Recovery still
fabricates nothing — a range never becomes a rep count, and an unreadable
segment blocks the split rather than being dropped. The FM layer still gets its
one shot at the full line before any of this runs.

## Not yet

Segments are re-parsed from text when their turn comes (no draft is cached), so
a queued segment can still land on the recovery card rather than a confident
draft — fine, that's the same card. Auto-parsing the popped segment after a
save was considered and skipped: it would stomp the "Saved N sets" / PR notice
moment. A multi-name FM draft would still be mangled by the single-exercise
card; that path is iOS 26-gated and untouched here.
