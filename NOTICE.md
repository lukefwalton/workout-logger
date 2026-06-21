# Notices & Attributions

Private Workout Logger (WorkoutChatLog)
Copyright (c) 2026 Luke Walton

This project is licensed under the MIT License. See [LICENSE](LICENSE) for
details.

The copy rule for this project (from the spec's scavenger discipline):

```
Copy:        MIT, Apache-2.0, BSD, Unlicense   (notice preserved)
Study only:  GPL, AGPL, unknown / no license
Never:       no or unclear license · snippets without clear terms ·
             assets/icons/images unless separately licensed
```

No third-party **code** is bundled in the app. Anything reused is logged below,
every time, with enough detail to answer "where did this come from?" later.

---

## Reuse log

### free-exercise-db — exercise seed vocabulary
- **Source:** https://github.com/yuhonas/free-exercise-db
- **Retrieved:** 2026-05-28 (`main`; consulted `schema.json` and `README.md`)
- **License:** The Unlicense (public domain)
- **What was used:** the 17-value muscle vocabulary used for `primaryMuscles` /
  `secondaryMuscles` (abdominals, abductors, adductors, biceps, calves, chest,
  forearms, glutes, hamstrings, lats, lower back, middle back, neck, quadriceps,
  shoulders, traps, triceps).
- **Copied verbatim?** No. `Resources/seed_exercises.json` (89 lifts, muscle
  tags, and aliases) was authored for this app; only the muscle vocabulary is
  aligned to the dataset so tags stay consistent with a defensible source.
- **Notice required?** No — the Unlicense waives copyright. Credited here
  voluntarily.
- **Used as:** seed data.

### `lfwdesignsystem` — shared design-system package (linked dependency)
- **Source:** vendored copy of the `lfwdesignsystem` Swift Package (same
  author), copied from the `scout-tasks` monorepo where it lived as a sibling.
  Originally the `Color(hex:)` initializer pattern and a few brand
  color hex values adapted from `stop-political-spam-texts-ios` into
  `WorkoutChatLog/App/Theme.swift`; later extracted into the shared package
  all three apps consume.
- **License:** MIT (`LICENSE` in the package).
- **What is used:** the app links the whole package via XcodeGen
  (`path: lfwdesignsystem`) — `LFWColors`, `Color(lfwHex:)`, the onboarding
  kit, and the CTA button style. `App/Theme.swift` forwards to it. No logos,
  fonts, or image assets.
- **Used as:** linked Swift Package (compiled into the app).

### XcodeGen — build tooling (not shipped)
- **Source:** https://github.com/yonaskolb/XcodeGen
- **License:** MIT.
- **What was used:** generates `WorkoutChatLog.xcodeproj` from `project.yml` at
  dev time. None of its code is compiled into or shipped with the app.

---

No GPL/AGPL/unlicensed code was copied. Future reuse must add an entry here in
the same format before the code lands.
