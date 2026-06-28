# 024 — App Store shipped (v1.0, June 2026)

Private Workout Logger **v1.0** was approved and released on the App Store in June
2026.

- **App Store:** https://apps.apple.com/us/app/private-workout-logger/id6782669888
- **Product page:** https://lukefwalton.com/private-workout-logger/
- **Price:** $4.99, no subscription
- **Apple ID:** 6782669888
- **Bundle ID:** `com.lukewalton.workoutchatlog`
- **Shipped build:** 1.0 (3) — marketing version 1.0, build 3

## What v1.0 included

Everything listed under **Shipped in v1.0** in the root [README](../../README.md):
deterministic parser + FM fallback, Today/History/Progress/Settings, widget,
HealthKit opt-in, OCR import, export/import, supplements, rest timer, and the full
privacy posture (no account, no server, Data Not Collected).

Review notes that got it through: [app-store-review-notes.md](../app-store-review-notes.md).

## Post-launch (before v1.0.1)

Real gym testing on build 3 exposed parser and logging friction — shorthand that
didn't match exactly dead-ended, name-only recovery was weak, and several common
lifts/aliases were missing. Fixes landed on `main` after ship:

| PR | What |
|---|---|
| [#4](https://github.com/lukefwalton/workout-logger/pull/4) | Forgiving set logging, posterior-chain seeds, assisted pull-ups |
| [#6](https://github.com/lukefwalton/workout-logger/pull/6) | Flexible parser: trailing punctuation, `×` as `x`, `@`-glued loads, lossless swap, recovery drafts keep typed name |

**Next upload:** v1.0.1 (build 4) — bump in `project.yml`, archive, submit as an
App Store update with a short "What's New" focused on gym-floor parsing.

### Suggested What's New (v1.0.1)

```
Smoother gym-floor logging: the parser accepts more shorthand variants (× for x,
@ glued to weight, trailing punctuation) and recovers gracefully instead of
dead-ending. Better handling for assisted pull-ups and more posterior-chain
exercises in the library.
```

## Release checklist (repeat for each update)

1. Bump `MARKETING_VERSION` and/or `CURRENT_PROJECT_VERSION` in `project.yml`.
2. `bash scripts/generate.sh` → open `WorkoutChatLog.xcodeproj`.
3. **Product → Archive** (Any iOS Device) → confirm version/build in Organizer.
4. **Distribute App → App Store Connect → Upload**.
5. App Store Connect → new version → attach build → What's New → submit for review.
6. Update this doc (or add `025-…`) when the update ships.
