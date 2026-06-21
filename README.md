# Private Workout Logger

> **No subscription. No cloud. No tracking.**

A local-first iOS workout tracker — shorthand logging, on-device parsing, progress
charts, and optional HealthKit. **[$4.99 — product page](https://lukefwalton.com/private-workout-logger/)**
(App Store, no subscription).

## Support

Problems, bugs, or questions:

- [GitHub Issues](https://github.com/lukefwalton/workout-logger/issues)
- [luke@lukefwalton.com](mailto:luke@lukefwalton.com)

Website: [lukefwalton.com](https://lukefwalton.com) · App page:
[private-workout-logger](https://lukefwalton.com/private-workout-logger/)

## Source

Public repository, **copyright Luke F. Walton (LFW)** — including
[`lfwdesignsystem/`](lfwdesignsystem). Not open source (no MIT or similar grant).
You may read and build locally to verify privacy claims; see [LICENSE](LICENSE).
Privacy details: [docs/privacy.md](docs/privacy.md).

> No account. No server. Your data lives on your phone, and the processing
> burden is the device's, by design.

## Doctrine (the part that doesn't change)

- **Local-first.** On-device SQLite is the single source of truth.
- **On-device by default.** Any future AI runs on the phone; cloud is an opt-in
  experiment, never a tier or a dependency.
- **Model proposes, app confirms, app writes.** The model never mutates the
  database, never writes SQL, never touches chart math. That boundary is what
  keeps the data honest while everything above it stays experimental.
- **You own your data.** Full export is a first-class goal (Track 6) — no lock-in.

### Not medical or coaching advice

Private Workout Logger tracks what you log. It does not diagnose, treat,
prescribe, or coach. This isn't only product taste — Apple's Foundation Models acceptable-use
terms prohibit regulated-healthcare use, so it's a license condition we hold
from day one, well before any model is wired up.

## Status

**v1.0** — submitted to the App Store (June 2026). [`docs/learnings/`](docs/learnings/)
records what each build step taught us along the way.

Shipped in v1.0:
- XcodeGen project (app + widget + unit-test targets), SwiftUI four-tab shell
- Domain models (`WorkoutDraft`, `SetDraft`, `SetType`, `WeightUnit`,
  `WorkoutLoadKind`) and a typed `AnalyticsPolicy`
- SQLite schema + migrations, seeded canonical exercise library (89 lifts)
- The single write path: `WorkoutDraft → validate → transaction → save`
- Deterministic parser for set shorthand with decline-on-ambiguity tests, plus
  an opt-in on-device Foundation Models fallback for prose — model proposes,
  app confirms, app writes
- Today tab free-form logging, plan mode, confirmation before save, "new
  exercise" confirmation, and a rest timer with opt-in local notifications
- History view + edit, Swift Charts progress (e1RM, volume), PR detection and
  achievements, "last time" context, calorie estimate, plate calculator
- Exercise library: fuzzy + on-device-embedding name resolution, rename /
  merge / delete, manual creation
- OCR import of paper logs (Vision, entirely on-device)
- Settings export/share: markdown AI handoff, versioned JSON full export —
  and JSON import with a dry-run pass
- Home Screen widget reading the shared App Group database
- Opt-in HealthKit: bodyweight read, one strength workout written per
  finished session
- Supplement tracking with trends

Not in v1.0: cloud sync (and by doctrine, cloud would only ever be an opt-in
experiment, never a tier or a dependency).

## Building

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen), so the `.xcodeproj` is never
committed.

```bash
brew install xcodegen
cp project.local.yml.example project.local.yml
# Edit project.local.yml — set DEVELOPMENT_TEAM (gitignored; never commit).
bash scripts/generate.sh
open WorkoutChatLog.xcodeproj
```

Set your `DEVELOPMENT_TEAM` in `project.local.yml` or in Signing & Capabilities. The app uses minimal,
**on-device** entitlements — an App Group (`group.com.lukewalton.workoutchatlog`)
so the app and the Home Screen widget share one SQLite file, opt-in **HealthKit**
(read bodyweight, write one strength workout per finished session — both behind an
in-app toggle and permission), opt-in **local notifications** (the rest timer's
"rest's over" alert, requested in context the first time you start a timer — never
at launch), and, later, optional Camera. Register the App Group and enable
HealthKit for your team in the Apple Developer portal. There is still no server, no
account, and no tracking.

> **v1.2 is a clean schema reset.** If you ran an earlier local build, delete the
> app (or wipe its App Group container) before launching this one. The app has
> never shipped, so there is nothing to migrate — a pre-v1.2 database is rejected
> at launch with a clear reset message rather than being silently mis-read.

Run the unit tests with `⌘U`, or:

```bash
xcodebuild test -scheme WorkoutChatLog \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

## Layout

```
.
├── project.yml                      # XcodeGen spec (app + widget + tests)
├── WorkoutChatLog/
│   ├── App/                         # @main, four-tab shell, theme, widget refresh
│   ├── Features/                    # Today · History · Progress · Settings · exercise library · supplements · rest timer · OCR capture
│   ├── Health/                      # HealthKit service + rest-timer notifications
│   ├── Model/                       # drafts, policy, achievements, calorie/plate math, fuzzy + embedding matching
│   ├── Parsing/                     # deterministic parser · Foundation Models fallback · orchestrator
│   ├── Shared/                      # App Group database path, canonical date format, widget reader
│   ├── Storage/                     # SQLiteDB, Schema, WorkoutStore (the write path), validator, seed loader
│   ├── Vision/                      # on-device OCR text recognition
│   └── Resources/seed_exercises.json
├── WorkoutWidget/                   # Home Screen widget target (reads the shared DB)
├── WorkoutChatLogTests/             # parser, store, analytics, health, widget, import, …
├── lfwdesignsystem/                 # vendored LFW design-system Swift Package (onboarding + chrome)
├── scripts/                         # App Group identifier sync guardrail (runs in CI)
└── docs/learnings/                  # what each step taught us
```

The build depends on the LFW design-system Swift Package vendored in-repo at
[`lfwdesignsystem/`](lfwdesignsystem), resolved by relative path.

## License & attribution

**Copyright (c) 2026 Luke F. Walton — all rights reserved.** See [LICENSE](LICENSE).
The App Store build is the official release. [NOTICE.md](NOTICE.md) logs
third-party references only (seed vocabulary, build tooling). `lfwdesignsystem` is
same author, same copyright.

Going public? See [docs/publishing-source.md](docs/publishing-source.md).
