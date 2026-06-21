# 003 — The Ugly Save UI

Step 3 closes the first real loop: type a set in shorthand → parse → confirm →
it's in the database. Deliberately plain. The point is the round trip working on
my own phone, not the polish.

## The doctrine, made literal

The spine's rule — *model proposes, app confirms, app writes* — stops being an
abstract principle here and becomes three concrete UI states:

1. **Propose.** `DeterministicParser` turns the typed line into a pending
   `WorkoutDraft`.
2. **Confirm.** The user sees the parsed sets and can name the exercise (a bare
   `3x10` arrives nameless), with Save gated until there's a name.
3. **Write.** Only then does `WorkoutStore.save` run — the same single write path
   the parser tests already exercised.

Nothing auto-saves. The 0-weight of a bare scheme shows up as `BW × 10` in the
confirm card, where it's either accepted as bodyweight or the user types a real
weight — exactly the guard I promised in step 2 instead of rejecting 0 at save.

## Logic out of the view

`TodayModel` (an `ObservableObject`) holds the whole flow — `parse`,
`setExerciseName`, `save`, `discard`, and a `Status` (idle / declined / saved /
failed) — so the behavior is unit-tested without a running UI (`TodayModelTests`).
`TodayView` is thin glue: a text field, a Parse button, a confirm section, and
status messages. Keeping the decisions in the model is the same instinct as the
spine's pure `AnalyticsPolicy` and the parser's fixtures — the testable surface
is where the judgment lives.

Two small decisions worth noting:
- **Shared name and weight edits fan out to all sets.** One entry is one
  exercise at one load, so the confirm card shows a single exercise field and a
  single weight field, and editing either updates every set in the pending draft.
  This is what makes the bare-scheme `0` an actual *placeholder*: you name
  `squat 3x10` and type `135`, and it saves as real weight — not an accidental
  bodyweight entry (the gap the review caught). Per-set reps editing stays
  deferred; for varied reps you type the fuller shorthand (`135 for 8,8,7`).
- **Decline is a first-class state, not an error.** When the deterministic parser
  returns nil, the UI says "couldn't read that one yet" and points at examples —
  honest about the boundary, and the exact seam where Track 2 (the on-device LLM)
  will later take over instead of leaving the user stuck.

## The honest caveat

I can't run a simulator in this environment, so **`TodayView` is unverified** —
written correctly-by-inspection, but its first real test is an Xcode/device
launch. The *logic* (`TodayModel`) is covered by tests; the view is thin on
purpose precisely because it's the part I can't exercise here. Flagging that
rather than implying I watched it work.

## Review round

The review caught a real parser bug (a red flag) surfaced now that the parser
feeds a UI: `curl 10 kg x 12` was read as **10 sets of 12** instead of **1 set of
10 kg × 12**. The standalone `kg` is stripped before disambiguation, and only a
*glued* unit (`10kg`) forced the weight reading — so the separated small-unit
form fell through to the "small number → set count" rule. Fixed by carrying
"an explicit unit was present" into the `A x B` disambiguation; added regression
fixtures (`10 kg x 12`, `5 lb x 15`). The lesson restated: the parser's ambiguity
rules are product behavior now — a wrong guess is silent bad data, so each
ambiguous shape earns a fixture.

Deferred (yellow): moving `AppDatabase.makeStore()` / `exerciseCount()` off the
main actor. It's synchronous file/SQLite work on the SwiftUI `.task` path —
imperceptible for a 71-row seed, but the first place migration/seed growth would
hitch the UI. Flagged for when the data grows rather than restructuring startup
concurrency blind (no simulator here to verify the async hand-off).

## Next

With a real save path in the UI, the natural follow-ons are the History/audit
view (read back what was saved — the trust surface), then Swift Charts (Track 4),
then the Foundation Models fallback (Track 2) for everything the deterministic
parser declines.
