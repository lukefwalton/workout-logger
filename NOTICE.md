# Notices & Attributions

Private Workout Logger (WorkoutChatLog) and LFWDesignSystem
Copyright (c) 2026 Luke F. Walton

All rights reserved. See [LICENSE](LICENSE). The app and `lfwdesignsystem/` are
original work by the same author.

Third-party components referenced by this project remain under their own licenses.
The copy rule for scavenged code (internal discipline):

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

### `lfwdesignsystem` — LFW design-system package (same author)
- **Source:** vendored Swift Package in this repo (`lfwdesignsystem/`).
- **Copyright:** Luke F. Walton — same terms as root [LICENSE](LICENSE).
- **What is used:** linked via XcodeGen — `LFWColors`, onboarding kit, CTA
  button style. `App/Theme.swift` forwards to it.
- **Used as:** linked Swift Package (compiled into the app).

### XcodeGen — build tooling (not shipped)
- **Source:** https://github.com/yonaskolb/XcodeGen
- **License:** MIT.
- **What was used:** generates `WorkoutChatLog.xcodeproj` from `project.yml` at
  dev time. None of its code is compiled into or shipped with the app.

---

No GPL/AGPL/unlicensed code was copied. Future reuse must add an entry here in
the same format before the code lands.
