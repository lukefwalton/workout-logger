# App Store Review Notes — Private Workout Logger

**Status:** v1.0 approved June 2026; **v1.1** shipped (build 4); **v1.2** in review
prep (build 5) —
[App Store listing](https://apps.apple.com/us/app/private-workout-logger/id6782669888).
Keep these notes for future updates; paste into App Store Connect → App Review
Information → Notes when submitting a new version.

These notes are for App Review (paste into App Store Connect → App Review
Information → Notes). They explain the privacy-first design so the reviewer can
exercise the whole app without friction.

## No account — no demo credentials needed

Private Workout Logger has **no account system, no sign-in, and no server.** There is nothing
to log into; there are no demo credentials. Launch the app and use it immediately.

## Everything works with all permissions denied

The app is fully functional with HealthKit, notifications, camera, and Apple
Intelligence all unavailable or denied:

- **Logging is deterministic-first.** Type a set in shorthand (e.g. `bench 135x8`,
  `3x10 @ 135`, `bw x12`) → confirm → save. This path needs no AI and no network.
- **Apple Intelligence is an optional fallback.** On a device without it, an
  unparseable entry simply asks you to type it manually — no crash, no degraded core.
- **HealthKit is opt-in.** Off by default. The calorie estimate uses a manual
  bodyweight field in Settings when Health is unavailable, and is always shown as a
  rough "~X kcal (estimate)" — never written to Apple Health as energy.
- **Notifications** (rest timer, a later feature) are requested in context, never at
  launch.

Suggested smoke test on a clean install:
1. Decline every permission prompt.
2. Today tab → type `bench 135x8` → Save. → A set is logged locally.
3. Today tab → type `run 20 min` → Save. → Cardio is logged (v1.2+).
4. History tab → the workout appears; set a bodyweight in Settings → a rough
   calorie estimate shows.
5. Progress tab → strength trends and cardio charts render from local data.

## Data: not collected

Private Workout Logger collects, transmits, and sells **nothing** — no analytics, no ads, no
third-party SDKs, no tracking, no IDFA, no ATT prompt. All data is stored in a
private on-device database (the app's App Group container) and leaves the phone only
if the user explicitly exports it. This matches the **App Privacy: Data Not
Collected** label and the bundled `PrivacyInfo.xcprivacy`.

- Privacy policy: hosted from the repository (`docs/privacy.md`).
- Required-reason API: **UserDefaults** only (`CA92.1`, app-functionality
  persistence of plans/settings).

## HealthKit usage (5.1.3), when enabled

- Read: most recent bodyweight, to estimate calories on-device.
- Write: **one** strength-training workout per finished session, only with the
  explicit in-app toggle **and** granted permission.
- Health data is never used for advertising, never written to iCloud, and the
  estimated calorie value is **never** written as `activeEnergyBurned`.

## Not medical or coaching advice

Private Workout Logger tracks what you log. It does not diagnose, treat, prescribe, or coach,
and the listing does not claim otherwise. AI is described honestly as on-device
parsing assistance; estimates are clearly labeled.
