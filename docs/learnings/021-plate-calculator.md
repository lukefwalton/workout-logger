# 021 — Plate calculator

Third ergonomics feature (spec §4). A pure function turns a target load into the plates
per side, honestly reporting when a target can't be made exactly.

## What shipped

- **`Model/PlateCalculator.swift`** — pure, store-free, AI-free math:
  `loadout(target:bar:plates:unit:) -> PlateLoadout?`. Plates load symmetrically, so it
  works on per-side weight `(target − bar) / 2` and greedily loads the largest plate that
  fits. `PlateLoadout` carries `perSide`, `achieved`, `remainder`, `unit`, and an `isExact`
  flag. Default plate inventories (`defaultPlatesLb` / `defaultPlatesKg`) and a
  `perSideText` formatter live alongside.
- **`TodayView`** — a "Plate calculator" button under the weight field on the confirm card
  (shown only when there's a real `> 0` external load), opening `PlateCalculatorSheet`. The
  sheet shows per-side plates for a configurable bar (`@AppStorage` bar weight, one key per
  unit), and when the load isn't exact, states the nearest-achievable total and the
  shortfall — never a silent round.

## Decisions

- **Honest about non-achievable targets** (the core §4 requirement): an unreachable target
  is **not** an error and **not** rounded. It returns a non-exact `PlateLoadout` whose
  `achieved` is the nearest the plates can make and whose `remainder` is exactly how far
  off (positive = short of the bar's reach, negative = the target is below the bar). The UI
  surfaces that as "Can't make it exactly — nearest is X, N short."
- **nil means nonsensical input only** (non-finite/negative bar, non-finite target), not an
  unreachable target — so the caller distinguishes "bad request" from "honest near miss."
- **Never silently converts units** (`WeightUnit` doctrine): the function operates entirely
  in the supplied unit with that unit's plate set; lb and kg never mix.
- **Pure + fully testable here.** No store, no UI dependency in the math — the whole
  contract is unit-tested. Bar weight is a UI preference (`@AppStorage`), not part of the
  function, so the math stays deterministic and injectable.

## Validation (math runs here; UI not compiled — Linux container, no Xcode)

- **Algorithm prototyped in Python** first; all fixtures pass: exact loads (135/45→45,
  225/45→45+45, 100/45→25+2.5), odd targets (47/45 → nearest = bar, 2 short), below-bar,
  target==bar, kg sets (60/20→20, 61/20 → 60, 1 short), empty plate set, and the
  no-nearest variant. `PlateCalculatorTests` mirrors these.
- **`PlateCalculatorSheet` is correct-by-inspection** (not run in a simulator): it only
  renders `PlateCalculator` output and persists the bar weight.

## Review round (surmado) — kg precision + external-only + a stale test

Two 🔴 and a 🟡, all fixed:

- **🔴 1.25 kg plate rendered as "1.3".** `PlateCalculator.format` rounded to one decimal,
  but the default kg inventory has a **1.25 kg** plate (22.5 kg on a 20 kg bar = one 1.25
  per side). Now formats to two decimals with trailing zeros trimmed (`45`→"45",
  `2.5`→"2.5", `1.25`→"1.25"). Added a 1.25-plate regression test. Re-validated in Python.
- **🔴 Stale formatting test.** `testLastTimeSummaryDropsTrailingZeroWeight` still expected
  the pre-unit strings (`"225×5"`); updated to the unit-carrying form (`"225 lb×5"`,
  `"102.5 kg×5"`). (A genuine miss from the last-time unit change — caught by the bot, which
  reads the diff even though the Linux CI can't run the Swift tests.)
- **🟡 CTA not barbell-gated.** The plate button showed for any positive load; now gated to
  `loadKind == .external`, so it never appears for `bodyweightPlus` / `assisted` entries
  where "load the bar" would be misleading. (Answers the reviewer's question: barbell-only.)
