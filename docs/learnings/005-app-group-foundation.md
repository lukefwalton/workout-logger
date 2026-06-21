# 005 — App Group Foundation (v1.2 PR 1)

The first v1.2 gate: move the database somewhere the Home Screen widget (PR 12)
and HealthKit-adjacent code (PR 10/11) can actually reach it, and satisfy the
App Store privacy requirement — without relocating any data, because the app has
never shipped.

## The real decision: container now, not later

The widget runs in its own process. Two processes can only share a SQLite file
if it lives in a shared **App Group** container, not in either process's private
Application Support sandbox. WAL mode (already set in `SQLiteDB.init`) makes the
cross-process *reads* safe; the App Group is what makes the *file* reachable at
all. So the container move is a prerequisite for PR 12, and doing it first means
no later PR has to migrate a database between locations.

`AppDatabase.makeStore()` now opens
`containerURL(forSecurityApplicationGroupIdentifier:)` +
`workout.sqlite`. The old build opened Application Support. There is **no
migration path** between the two on purpose: zero installs means there is no
prior database to carry over, so a relocation shim would be dead code guarding a
case that can't exist. The spec is explicit — "No relocation — zero installs."

## Fail loudly, don't fall back

`containerURL(...)` returns nil only when the entitlement is missing from the
build or the provisioning profile — a developer/signing mistake, never a normal
runtime condition. The tempting "fall back to a private sandbox path" is exactly
wrong here: it would let the app and the widget silently open *two different
databases* and look fine until the widget shows stale or empty data. So
`databaseURL()` throws `StoreError.containerUnavailable`, which surfaces through
the existing `StartupErrorView` (raw detail in DEBUG only). There is no server to
fall back to; an honest hard failure in dev beats a silent split-brain in prod.

## The seam: one identifier, two files

The group identifier lives in two places that can't see each other —
`project.yml`'s `com.apple.security.application-groups` entitlement (consumed by
XcodeGen at `xcodegen generate`) and `AppGroup.identifier` in Swift (consumed at
runtime). There is no build-time bridge between a Swift constant and a plist, so
they're kept in sync by a comment on each side **and** a CI guardrail:
`scripts/check_appgroup_sync.sh` extracts both and fails the build if they drift.
That check is the one piece of this PR's acceptance that *can* run without Xcode,
so it runs in a path-scoped workflow (`.github/workflows/workout-chat-log-check.yml`)
mirroring the sibling app's `ios-privacy-check.yml`. XcodeGen generates the
`.entitlements` from `project.yml`, so the YAML — not a hand-edited plist — is the
single source of truth for the build side. The reviewer's other asks (a real
Apple-runtime check that `makeStore()` opens the container) stay human-on-device
steps; CI here can't sign or run an iOS target.

## Privacy policy

`docs/privacy.md` states the doctrine plainly: no account, no server, no
analytics, no tracking; all data on-device; Health (later) read with permission
and never transmitted; no estimated values written into Health energy data. It
needs to be hosted at a public URL before submission (PR 15), but the content is
the gate, and it's written now while the doctrine is fresh.

## Not compiled here

Built in a Linux container with no Xcode and no simulator. The change is
correct-by-inspection against Apple's documented `FileManager` container API and
XcodeGen's `entitlements` schema; the real proof — the app and a second target
opening the same container file on a device — is a human-on-device check, and
the test suite doesn't touch `makeStore()` (tests open `SQLiteDB(path:)`
directly), so nothing in the suite regresses from the move.
