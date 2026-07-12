# Engineering Standards

The doctrine this codebase is reviewed against — the durable rules, distilled
from the per-change rationale in [`docs/learnings/`](../docs/learnings/).
`CONTRIBUTING.md` covers *who* may change what; this file covers *how* changes
must behave.

## Architecture

- **Local-first.** On-device SQLite is the single source of truth. No server,
  no account, no cloud sync operated by us.
- **One write path per domain.** All SQL lives in `WorkoutChatLog/Storage/`.
  Strength saves funnel through `WorkoutStore.save` (draft → validate →
  transaction), cardio through `saveCardio`. Feature code never runs ad hoc
  SQL, and import inserts raw rows inside one transaction —
  `SQLiteDB.transaction` does not nest.
- **Model proposes, app confirms, app writes.** AI/ML output (Foundation
  Models parse, fuzzy/semantic suggestions, OCR) is a *proposal*; nothing
  lands without user confirmation, and AI never generates SQL or mutates the
  database.
- **Concurrency discipline.** Writes are `@MainActor`-gated; off-main reads go
  through `SQLiteDB.readTransaction` (serialized on the connection lock), and
  multi-read consumers use `WorkoutStore.snapshot` for a consistent view.
  FULLMUTEX alone is not an argument that a multi-statement closure is safe.

## Data honesty

- **Never invent a number.** A NULL weight stays nil ("honest-or-nothing"),
  calorie figures are clearly-labeled estimates, PRs are computed only against
  genuinely prior history, and charts compare an exercise only to itself.
- **Analytics are pure functions** over stored rows, unit-testable, no AI in
  the arithmetic.
- **Exports round-trip.** Timestamps are exported verbatim; imports are
  idempotent (re-importing a file adds nothing) without collapsing genuinely
  duplicate facts.

## Privacy

- Claims in UI copy, `docs/privacy.md`, and the README must describe the same
  product. The wording is "no **cloud** AI" — the optional parser uses Apple's
  on-device model, and no entry ever leaves the device.
- No analytics, no telemetry, no third-party SDKs. New entitlements or
  permissions require explicit opt-in UX and a privacy-policy update in the
  same change.

## Schema & compatibility

- Schema changes ship with a `Schema.migrate` step and tests; constraints that
  protect the data contract (CHECKs, UNIQUE indexes, FK cascades) live in the
  schema itself, not just in Swift.
- Export `schema_version` bumps are honest labeling: decode stays lenient for
  older files, and the frozen wire-shape tests are updated in the same commit
  as the DTO.

## Testing & CI

- Behavior that protects an invariant gets a test at the right altitude —
  connection/schema guarantees in `SQLiteDBTests`, store semantics in store
  tests, formatting in model tests. UI-only styling does not need tests.
- Conditional compilation must be provable in CI. Anything behind
  `#if canImport(...)` needs a job where the branch actually compiles (see
  `foundation-models-guard` in `ios-tests.yml`) — a green build on a toolchain
  without the SDK proves only the fallback.
- User-facing copy that enumerates data (previews, completion messages) is
  composed from one shared source so surfaces cannot drift apart.

## Code shape

- Files stay navigable: one type may span multiple focused files
  (`WorkoutStore+*.swift`), and a file trending past ~1,000 lines is a signal
  to find the next extraction boundary, not to keep appending.
- Comments record *why* (the constraint or trade-off), not *what*; significant
  decisions get a `docs/learnings/` entry in the same PR.
