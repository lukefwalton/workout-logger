# Security Policy

Private Workout Logger is a local-first iOS app. On-device SQLite is the single
source of truth — there is **no server, no account, and no tracking**, and the
app makes no network calls to a backend of its own. Optional integrations are
explicitly opt-in and stay on device: **HealthKit** (reads bodyweight, writes one
strength workout per finished session), **local notifications** (the rest
timer), **on-device OCR** (Vision), and an **on-device Foundation Models**
parsing fallback. That removes whole classes of vulnerability — but the app, the
widget, the optional integrations, and the build/release scripts can still have
bugs worth reporting privately.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Instead:

1. Email **[luke@lukefwalton.com](mailto:luke@lukefwalton.com)** with a
   description of the issue.
2. Include steps to reproduce, the affected area (app, widget, HealthKit, OCR,
   parsing, or a script), and the potential impact.
3. You'll get an acknowledgement within a few days. Please allow a reasonable
   window to ship a fix before disclosing publicly.

## In scope

- Any path that causes the app to make an unexpected network request, or to send
  workout/health data off the device
- On-device data exposure through the shared App Group SQLite database
- HealthKit read/write beyond the stated bodyweight-read / one-workout-write
  behavior
- Issues in the build/release scripts (`scripts/`) that could compromise a
  release archive or leak signing material

## Not a security issue

- Feature requests, visual/UI bugs, or parser mistakes with no security impact.
- Reminder: this repo is source-available, not open source — see
  [LICENSE](LICENSE). Security reports are welcome regardless.

## Supported versions

Fixes target the latest App Store release and the `main` branch. Older builds
are not separately patched.
