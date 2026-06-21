# 007 — Active Session Lifecycle (v1.2 PR 3)

The keystone behavioral fix: confirmed sets now append to **one** open session
until the user finishes it, instead of spawning a session per entry. Everything
downstream (History, Progress, Health, calories, the widget) depends on sessions
being real, multi-set things.

## The bug and the fix

The old write path created a fresh session for every confirmed entry, so a normal
workout fragmented into N one-set sessions. The fix is two-sided:

- **`save(_:into:)`** appends to the given session *if it's still open*, else
  adopts the one in-progress session, else opens a new one. **`TodayModel`** holds
  `activeSessionID`, captures the returned id, and passes it back on every later
  entry; finish clears it so the next entry opens fresh.

The first cut had `save` open a new session whenever `into:` was nil and trusted
`TodayModel` to keep it single. Review (correctly) flagged that as fragile: two
bare `save(_:)` calls, or a stale id, could create or append to the wrong row
while `currentOpenSession()` silently returned only the newest. So the store now
*enforces* single-open itself — it can never hold two open sessions regardless of
caller — and the low-level tests assert exactly that (`testTwoBareSavesStayInOneOpenSession`,
`testSaveIntoStaleClosedSessionDoesNotReopenIt`). `save(_:)` is therefore safe and
session-aware, not just a `TodayModel` convenience.

## set_index continuation — the collision trap

`sets` has `UNIQUE(session_id, set_index)`. Appending must continue from
`COALESCE(MAX(set_index), 0) + 1` for that session; restarting at 1 would collide
on the second entry and throw. This is the single most important line in the PR.

## Lazy open, single open

Sessions open lazily on the first saved set, so an empty session can't appear
through the normal path. `startSession` is the one explicit opener (for a
backdated workout) and it *enforces* the single-open invariant — a second open
session throws `WorkoutStoreError.openSessionExists`. After review it's enforced
in the **database too**: `idx_one_open_session`, a UNIQUE index over the constant
`(ended_at IS NULL)` restricted to open rows, makes "at most one open session" a
storage guarantee rather than only caller discipline — so a future second writer
(the widget process, PR 12) can't open two either. The app-level check still
fires first with a friendly error; the index is the backstop.

Reconcile is best-effort and must never block logging, but it no longer fails
*invisibly*: on a read/finish error it clears the in-memory active-session state
(so the banner can't keep showing a session it couldn't verify) and logs in
debug, self-healing on the next appear/save. Fully preventing a cross-day merge
when the DB read itself fails would mean blocking logging, which the doctrine
forbids — that residual is documented, not hidden.

## Stale auto-finish — "yesterday doesn't eat today"

If the app is left open across midnight (or for hours), the still-open session
must not absorb tomorrow's first set. `TodayModel.reconcileActiveSession(now:)`
runs on appear and before each save: if the open session's `lastSetAt ??
startedAt` is a different local calendar day, or older than a 6h gap, it
auto-finishes it (no metadata) and lets the next save open fresh; otherwise it
adopts it as active. `now` is injectable so the "next day" case is testable
without waiting (the set's `created_at` is always ~now, so the day boundary is
the lever, not a backdated set).

## Finish, and never-empty

`finishSession` stamps `ended_at` + feel/deload/notes — or **deletes** the
session if it somehow has zero sets, so an empty session can't linger. Feel and
deload are SF-Symbol pickers set at finish (off-days/deloads get excluded from
trends in PR 5, never hidden from History). `name` **and `notes` are COALESCEd**
so finishing without re-entering them preserves what was set at open (a plan
name, or the first entry's note) rather than nulling it — review caught that a
blank finish was overwriting open-time notes with nil. Session notes are thus
"authored at open, refined at finish." The stale auto-finish passes nil for all
metadata, so it too is non-destructive.

## Reverting PR 2's stopgap

PR 2 closed each session immediately (`ended_at = now`) because it had no
lifecycle yet. PR 3 opens sessions with `ended_at NULL` and closes them only at
finish — the real model. Reads/export grew to match: `WorkoutSetHistoryRow` gains
`sessionFeel`/`sessionIsDeload`/`sessionEndedAt`, `ExportedSession` gains
`ended_at`/`feel`/`is_deload`, and the export `schema_version` bumped to **2**
(import in PR 13 will handle both 1 and 2).

## Not compiled here

As with PRs 1–2: written correct-by-inspection on Linux with no Xcode. The
SwiftUI finish sheet and the banner are the least machine-checkable part; the
store lifecycle and `TodayModel` reconcile logic are covered by unit tests and
are where the real risk lives.
