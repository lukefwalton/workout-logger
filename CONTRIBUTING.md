# Contributing

Private Workout Logger is **public source, copyright Luke F. Walton** — not
open source (no MIT or similar license). The code is visible so you can verify
the privacy posture; the App Store build is the official release.

## Support & feedback

Having a problem with the app or the repo?

- **[GitHub Issues](https://github.com/lukefwalton/workout-logger/issues)** — bugs,
  questions, anything reproducible (include iOS version and app version when you can).
- **[luke@lukefwalton.com](mailto:luke@lukefwalton.com)** — same, or if you prefer email.
  Preferred for security or privacy concerns.

Product page: [lukefwalton.com/private-workout-logger](https://lukefwalton.com/private-workout-logger/)

## What we do not accept (without prior agreement)

- Pull requests that add features, refactors, or dependency changes.
- Forks published to the App Store or redistributed as competing products.
- Use of this codebase beyond personal local audit/build without written permission.

If you have a concrete fix and believe it should land, open an issue first. We
can discuss whether a PR makes sense case by case.

## Building locally (audit / development)

Generate the Xcode project with XcodeGen:

```bash
brew install xcodegen
cp project.local.yml.example project.local.yml
# Edit project.local.yml — set your DEVELOPMENT_TEAM (never commit this file).
bash scripts/generate.sh
open WorkoutChatLog.xcodeproj
```

Register the App Group (`group.com.lukewalton.workoutchatlog`) for your team if
you sign with your own Apple Developer account.

Run unit tests with `⌘U`, or:

```bash
xcodebuild test -scheme WorkoutChatLog \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

CI runs the unit suite on macOS (`.github/workflows/ios-tests.yml`) and an App
Group identifier guardrail (`.github/workflows/checks.yml`).

## Architecture ground rules (if we do accept a change)

- Local-first: on-device SQLite is the single source of truth.
- One write path: `WorkoutDraft → validate → transaction → save` via `WorkoutStore`.
- Model proposes, app confirms, app writes — AI/ML never mutates the database.
- Schema changes need migrations and tests.

See [LICENSE](LICENSE) for terms. Third-party reuse is logged in [NOTICE.md](NOTICE.md).
