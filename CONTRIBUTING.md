# Contributing

Thanks for considering a contribution to Private Workout Logger.

This is a local-first workout tracker whose core promise is that the user's
training history is correct, private, and theirs. The project values changes
that keep the write path narrow, the parser deterministic and honest about
ambiguity, and the data exportable.

## Ground rules

- Local-first: on-device SQLite is the single source of truth. No accounts,
  no servers, no analytics, no tracking.
- One write path: `WorkoutDraft → validate → transaction → save` via
  `WorkoutStore`. Don't add side doors to the database.
- Model proposes, app confirms, app writes. Any AI/ML feature (Foundation
  Models, embeddings, OCR) may *suggest* structured data, but never mutates
  the database, never writes SQL, never touches chart math.
- The parser declines on ambiguity rather than guessing. A wrong set logged
  silently is worse than a parse error the user can correct.
- Schema changes need a migration (or an explicit, documented reset story)
  and tests. User data outlives any refactor.
- HealthKit stays opt-in, and the app never writes estimated values into
  Health energy data.
- Any third-party reuse must be logged in `NOTICE.md` (same format, before
  the code lands). No GPL/AGPL/unlicensed code.

## Development

Generate the Xcode project with XcodeGen:

```bash
brew install xcodegen
xcodegen generate
open WorkoutChatLog.xcodeproj
```

Set `DEVELOPMENT_TEAM` in Signing & Capabilities, and register the App Group
(`group.com.lukewalton.workoutchatlog`) for your team — the app and the
Home Screen widget share one SQLite file through it.

Run the unit tests with `⌘U`, or:

```bash
xcodebuild test -scheme WorkoutChatLog \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

CI runs the unit suite on a macOS runner
(`.github/workflows/ios-tests.yml`) and a config guardrail
that keeps the App Group identifier in `project.yml` and
`Shared/SharedDatabase.swift` in sync
(`.github/workflows/checks.yml`). Run the guardrail locally
with:

```bash
bash scripts/check_appgroup_sync.sh
```

## Pull requests

Good pull requests usually include:

- A short explanation of the user problem being addressed (a lift that
  wouldn't parse, a PR that wasn't detected, a chart that misled).
- Tests for parser, validator, store, migration, PR-detection, or export
  changes when relevant.
- Screenshots for visible UI changes.
- Confirmation that the privacy posture in `docs/privacy.md` still holds.

## Developer Certificate of Origin

This project uses the Developer Certificate of Origin instead of a contributor
license agreement. By signing off a commit, you certify that you have the
right to submit the contribution under this project's license (MIT — see
`LICENSE`).

Sign off commits with:

```bash
git commit -s
```

See `DCO.md` for the full text.
