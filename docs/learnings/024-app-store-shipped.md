# 024 — App Store release history

Private Workout Logger on the App Store:
https://apps.apple.com/us/app/private-workout-logger/id6782669888

- **Product page:** https://lukefwalton.com/private-workout-logger/
- **Price:** $4.99, no subscription
- **Apple ID:** 6782669888
- **Bundle ID:** `com.lukewalton.workoutchatlog`

Review notes for App Review: [app-store-review-notes.md](../app-store-review-notes.md).

---

## v1.0 — June 2026 (build 3)

First public release. Everything under **Shipped in v1.0** in the root
[README](../../README.md): deterministic parser + FM fallback, Today/History/
Progress/Settings, widget, HealthKit opt-in, OCR import, export/import,
supplements, rest timer, full privacy posture.

---

## v1.1 — June 2026 (build 4)

Post-launch gym fixes after v1.0 felt too brittle on the floor.

| PR | What |
|---|---|
| [#4](https://github.com/lukefwalton/workout-logger/pull/4) | Forgiving set logging, posterior-chain seeds, assisted pull-ups |
| [#6](https://github.com/lukefwalton/workout-logger/pull/6) | Flexible parser: trailing punctuation, `×` as `x`, `@`-glued loads, lossless swap |
| [#7](https://github.com/lukefwalton/workout-logger/pull/7) | Docs + version bump |
| `466e40d` | Xcode warning cleanup before archive |

**What's New (shipped):**
```
Smoother gym-floor logging: the parser accepts more shorthand variants (× for x,
@ glued to weight, trailing punctuation) and recovers gracefully instead of
dead-ending. Better handling for assisted pull-ups and more posterior-chain
exercises in the library.
```

---

## v1.2 — in prep (build 5)

Cardio, reliability, and polish since v1.1.

| Theme | PRs / learnings |
|---|---|
| Cardio ingestion | [#8](https://github.com/lukefwalton/workout-logger/pull/8) — [025](025-forgiving-cardio-ingestion.md) |
| Cardio export/Progress/widget | [#15](https://github.com/lukefwalton/workout-logger/pull/15) — [027](027-cardio-first-class.md) |
| Parser reliability | [#12](https://github.com/lukefwalton/workout-logger/pull/12) — [026](026-multi-entry-splitting.md) |
| Bug audit | [#13](https://github.com/lukefwalton/workout-logger/pull/13) — overflow, OCR cross-day, session reconcile |
| Design | [#10](https://github.com/lukefwalton/workout-logger/pull/10), [#11](https://github.com/lukefwalton/workout-logger/pull/11), [#14](https://github.com/lukefwalton/workout-logger/pull/14) — green rebrand, LFWDesignSystem 2.x, new app icon |

**Suggested What's New (v1.2):**
```
Cardio is first-class: log runs, rows, and more alongside lifts — with Progress
charts, widget support, and backup export. Smarter parsing that recovers instead
of dead-ending. Visual refresh and bug fixes from real-world use.
```

---

## Release checklist (repeat for each update)

1. Bump `MARKETING_VERSION` and/or `CURRENT_PROJECT_VERSION` in `project.yml`.
2. `bash scripts/generate.sh` → open `WorkoutChatLog.xcodeproj`.
3. **Product → Archive** (Any iOS Device) → confirm version/build in Organizer.
4. **Distribute App → App Store Connect → Upload**.
5. App Store Connect → new version → attach build → What's New → submit for review.
6. Update this doc when the version ships.
