#!/usr/bin/env bash
#
# Guards the store's write-path boundary now that WorkoutStore spans multiple
# files. Splitting the type forced a handful of members to `internal` (Swift's
# `private` is file-scoped): the raw connection (`db`), and the registry
# writers the save/import transactions share (`resolveOrCreateExercise`,
# `insertExercise`, `insertAlias`). The compiler no longer stops feature code
# from calling them and bypassing `save`/`saveCardio` — so this check does.
# Companion to check_appgroup_sync.sh; runs in checks.yml on every PR.
#
# Rules, over production sources only (tests use @testable deliberately):
#   1. Outside WorkoutChatLog/Storage/, no reference to the store-internal
#      write helpers or to a store's raw `.db` connection.
#   2. Outside Storage/, only the Shared module may construct a SQLiteDB —
#      that is the widget's read-only path, which by design never links the
#      WorkoutStore write path.
#
# Exits non-zero with the offending lines when the boundary is crossed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0

# Production Swift sources outside the store's own directory.
mapfile -t SOURCES < <(find WorkoutChatLog WorkoutWidget -name '*.swift' \
  -not -path 'WorkoutChatLog/Storage/*' | sort)

# Rule 1: store-internal write surface stays inside Storage/.
# `\.db\b` catches any `<store>.db` access regardless of the variable name;
# the write helpers are matched by name (call or reference).
WRITE_SURFACE='resolveOrCreateExercise|insertExercise[( ]|insertAlias[( ]|\.db\b'
if hits=$(grep -nE "$WRITE_SURFACE" "${SOURCES[@]}" 2>/dev/null); then
  echo "❌ Store-internal write surface referenced outside WorkoutChatLog/Storage/:"
  echo "$hits" | sed 's/^/   /'
  echo "   Every workout write must go through the typed store API (save/saveCardio/…)."
  fail=1
fi

# Rule 2: SQLiteDB construction outside Storage/ is allowed only in Shared/
# (the widget's read-only connection).
if hits=$(grep -nE 'SQLiteDB\(' "${SOURCES[@]}" 2>/dev/null | grep -v '^WorkoutChatLog/Shared/'); then
  echo "❌ SQLiteDB constructed outside Storage/ (and outside the Shared read path):"
  echo "$hits" | sed 's/^/   /'
  echo "   Feature code gets its connection through WorkoutStore, never directly."
  fail=1
fi

if [[ $fail -ne 0 ]]; then
  exit 1
fi

echo "✅ Store write-path boundary intact: raw connection + registry writers only referenced under WorkoutChatLog/Storage/"
