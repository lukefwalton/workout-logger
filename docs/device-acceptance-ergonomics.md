# Device acceptance checklist — ergonomics + embeddings (§4 / PR 7)

The pure logic in this leg is unit-tested and the SQL is `sqlite3`-validated, but four
behaviors depend on **real Apple frameworks** (`UserNotifications`, `NaturalLanguage`) and
SwiftUI rendering that **cannot be exercised on the Linux CI** — they were written
correct-by-inspection and gated behind protocols + fakes. Run these on an Xcode simulator
and a real device before relying on the edge-case guarantees the comments describe.

## Rest timer (`RestTimerModel`, `UserNotificationsRestNotifier`)

- [ ] **In-context permission.** First time you tap "Start rest", the system notification
      prompt appears (never at app launch). Decline → the in-app countdown still runs to
      `0:00` and shows "Rest's over"; no crash.
- [ ] **Grant → background alert.** Allow, background the app, and confirm the "Rest's over"
      notification fires at the end of the countdown (not late).
- [ ] **Slow first-run prompt.** Take ~15s to tap "Allow" on the first timer; the alert
      should still fire when rest actually ends (scheduled against the absolute end time),
      not 15s late.
- [ ] **Restart just before expiry.** Start a short rest, let it get within a second or two
      of the end, then start a new rest. Confirm the **old** "Rest's over" alert never fires
      (the previous request is cancelled by exact id, synchronously).
- [ ] **Cancel.** Start a rest, "Stop" it, background the app — no notification fires.
- [ ] **Finish foregrounded.** Let a rest finish with the app open — you see "Rest's over"
      on screen and do **not** also get a redundant background buzz.
- [ ] **Settings duration.** Changing the default in Settings (60/90/120/180s) is reflected
      in the "Start rest" button and the countdown length.

## Layer-3 embeddings (`NLContextualEmbeddingExerciseMatcher`)

- [ ] **Symbol/API check.** Build the app for a device (iOS 17+). Confirm the
      `#if canImport(NaturalLanguage)` file compiles against the installed SDK — the symbol
      names (`NLContextualEmbedding`, `hasAvailableAssets`, `load()`, `requestAssets`,
      `embeddingResult(for:language:)`, `enumerateTokenVectors`) are from the spec and are
      **illustrative**; fix any that differ. This is the single gated file.
- [ ] **Simulator falls through.** On the simulator (where assets are documented to fail to
      load), confirm semantic suggestions are simply absent and resolution falls back to
      fuzzy/FM with no hang or crash.
- [ ] **Assets become available mid-session.** On a device with the model not yet
      downloaded: use the app (fuzzy-only), let assets finish downloading, and confirm a
      later low-confidence query starts surfacing `.semantic` suggestions **without**
      restarting the app (readiness is re-checked via `ensureLoaded`, and the candidate
      cache rebuilds because an empty list isn't cached while not-ready).
- [ ] **Quality spot-check.** A semantic near-miss that fuzzy ranks low (e.g. a descriptive
      phrase for a known lift) proposes the right canonical in the "Did you mean…?" row, and
      it never auto-applies or merges two canonicals.

## Other (SwiftUI, not rendered here)

- [ ] PR trophy notice, "Last time" row, and the plate-calculator sheet render correctly on
      the confirm/saved surfaces and read as intended (SF Symbols, not emoji).
- [ ] Plate calculator: an exact load (e.g. 135 lb) shows the right per-side plates; an
      odd/non-achievable target shows the honest "nearest is X, N short" line; a kg target
      using 1.25 kg plates renders "1.25", not "1.3".
