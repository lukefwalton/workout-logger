# Private Workout Logger — Privacy Policy

_Last updated: 2026-06-21_

Private Workout Logger is built privacy-first. The short version: **your data
stays on your device.** There is no account, no server, and no tracking.

## What we collect

**Nothing.** Private Workout Logger has no analytics, no advertising SDKs, no
crash reporting that leaves the device, and no third-party trackers. We do not
collect a name, an email, an advertising identifier, or any usage data. There
is no sign-up and no login because there is no account.

## Where your data lives

Everything you log — workouts, sets, exercises, notes, and settings — is stored
in a single on-device SQLite database. That database lives in a private App
Group container on your iPhone (`group.com.lukewalton.workoutchatlog`), which
lets the app and its Home Screen widget read the same file. It is never uploaded
anywhere by the app.

Standard iOS device backups (iCloud Backup or an encrypted local backup) may
include the app's container, the same as any other app's local data. That backup
is governed by Apple's privacy terms and your device settings, not by us; we
never transmit your log to our own servers because we don't have any.

## Apple Health (optional, opt-in)

If — and only if — you explicitly turn it on in Settings and grant permission,
Private Workout Logger can:

- **Read** your most recent body weight, used only on-device to estimate
  calories.
- **Write** one workout summary per finished session to the Health app.

Health data is used only inside the app. It is **never** transmitted off the
device, never used for advertising, and never written to iCloud by us. We never
write an estimated or guessed value (such as a rough calorie estimate) into
Health energy data. You can revoke Health access at any time in the iOS Settings
app, and the rest of the app keeps working.

## Camera and photos (optional, opt-in)

The Scan feature can read a workout written on paper by recognizing text in a
photo, entirely on-device (Apple's Vision framework). It runs only when you
choose it. Importing a photo uses the out-of-process iOS picker, which needs
no photo-library permission; using the camera instead asks for camera
permission in context. Recognized text goes through the same
confirm-before-save flow as typed input. No image or recognized text is
transmitted anywhere.

## Sharing is always your choice

When you tap an export or share action, you decide where the data goes (for
example, the iOS share sheet). The app prepares that payload locally; it is sent
only because you chose to send it.

## What Private Workout Logger does not do

- No accounts, no servers, no cloud sync operated by us.
- No analytics, no telemetry, no advertising, no ad identifiers, no ATT prompt.
- No selling or sharing of data — there is no data leaving the device to sell.
- No medical, diagnostic, or coaching claims. Calorie and "feel" figures are
  honest, user-entered or clearly-labeled estimates, not health advice.

## Children's privacy

The app collects no personal information from anyone, including children.

## Changes

If this policy changes, the updated version will be published here and the date
above will be revised.

## Contact

Questions about privacy or the app: [luke@lukefwalton.com](mailto:luke@lukefwalton.com),
or a [GitHub Issue](https://github.com/lukefwalton/workout-logger/issues).
Website: [lukefwalton.com](https://lukefwalton.com)
