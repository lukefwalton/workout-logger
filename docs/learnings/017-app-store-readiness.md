# 017 — App Store submission readiness (v1.2 PR 15)

The final gate: mostly configuration + honesty, but it's exactly where privacy-first
local apps get bounced. Largely doable here (the manifest + docs); the final upload
validation and a clean-device pass are on-device steps.

## The privacy manifest is an automated *upload* gate

`PrivacyInfo.xcprivacy` is validated at submission, so getting it right is the
difference between an upload that goes through and one that's rejected before a human
ever sees it. The app's manifest declares:

- `NSPrivacyTracking = false`, empty `NSPrivacyTrackingDomains` — no tracking.
- empty `NSPrivacyCollectedDataTypes` — **Data Not Collected** (true: no analytics, no
  server, no third-party SDK), which also backs the App Privacy label.
- `NSPrivacyAccessedAPITypes`: **UserDefaults only**, reason `CA92.1`.

The required-reason entry is the part you can get wrong by omission, so I **audited
the codebase** rather than guess. UserDefaults is used (plan/timer/settings
persistence + `@AppStorage`) → declared. The only other system calls into
file/disk-shaped APIs are `FileManager.containerURL` and `temporaryDirectory`, and
**neither is on Apple's required-reason list** (the required-reason file API is
`NSFileManager` *creation/modification-date* access, which we don't call), so no entry
is needed. We touch no disk-space, no system-boot-time, and no `stat`-timestamp
required-reason API. I wrote the manifest via `plistlib` and round-trip-verified it
parses.

It rides the existing `WorkoutChatLog/Resources` resources build phase (next to
`seed_exercises.json`), so it's bundled with no new wiring.

## Privacy policy already existed; review notes are the new artifact

`docs/privacy.md` was authored back in PR 1 (Data Not Collected, HealthKit, camera) —
PR 15 just relies on it as the hosted policy URL (App Review 5.1.3 needs a reachable
URL once HealthKit ships). The genuinely new doc is `docs/app-store-review-notes.md`:
the no-account / no-demo-credentials statement, and the **deny-everything-still-works**
walkthrough (decline all permissions → deterministic log → confirm → save → History →
Progress with manual bodyweight). That path is the spec's core acceptance criterion,
and stating it plainly for the reviewer is what avoids a needless rejection.

## What stays on-device

Final `xcodebuild`/Xcode upload validation, the App Privacy answers entered in App
Store Connect, and a clean-install pass with HealthKit/notifications/camera/Apple
Intelligence all unavailable are human steps — this environment has no Xcode and
can't submit. The manifest, the policy, and the review notes are the artifacts that
make those steps a formality.

## Merge-time coordination (carries across the v1.2 PRs)

- **Widget manifest:** when the widget (PR 12, #228) lands, the extension is a
  separate bundle and needs its **own** `PrivacyInfo.xcprivacy`. The widget reads
  SQLite + WidgetKit and uses **no UserDefaults**, so its manifest is the same
  no-tracking / no-collection shell, with the `NSPrivacyAccessedAPITypes` array
  **empty** (it touches no required-reason API). Add it under `WorkoutWidget/`.
- **Camera (5.1.1):** only relevant if OCR (PR 14) ships; its usage strings + the
  works-without-camera path would join these notes then.
- **HealthKit (5.1.3):** the policy URL + opt-in framing above assume PR 10 (#225) is
  merged; harmless if it isn't (the section just doesn't apply).
