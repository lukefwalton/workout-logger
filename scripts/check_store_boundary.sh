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
# The guarded surface below is the COMPLETE write-capable set: the other
# cross-file internal members on WorkoutStore (`count`, `snapshot`,
# `exerciseID(slug:)`, `aliasesByExercise`, the ISO/date statics) are
# read-only or pure and deliberately not guarded. If a future split widens
# another write helper to internal, add it here in the same change.
#
# Rules, over production sources only (tests use @testable deliberately):
#   1. Outside WorkoutChatLog/Storage/, no reference to the store-internal
#      write helpers or to a store's raw `.db` connection.
#   2. Outside Storage/, only the Shared module may construct a SQLiteDB —
#      that is the widget's read-only path, which by design never links the
#      WorkoutStore write path.
#
# The script SELF-TESTS on every run before checking the real tree: it builds
# sandbox fixtures (clean, each violation class, the Shared allowance) and
# asserts the rules catch/pass them. A regex edit that silently weakens the
# guard therefore fails CI by itself, with no violation needed in the repo.
#
# Exits non-zero with the offending lines when the boundary is crossed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# `\.db\b` catches any `<store>.db` access regardless of the variable name;
# the write helpers are matched by name (call or reference).
WRITE_SURFACE='resolveOrCreateExercise|insertExercise[( ]|insertAlias[( ]|\.db\b'

# Check one tree. Prints violations; returns 0 clean, 1 violated, 2 unusable.
check_tree() {
  local tree="$1"
  local status=0
  local sources=()
  while IFS= read -r f; do sources+=("$f"); done < <(
    cd "$tree" && find WorkoutChatLog WorkoutWidget -name '*.swift' \
      -not -path 'WorkoutChatLog/Storage/*' 2>/dev/null | sort)
  if [[ ${#sources[@]} -eq 0 ]]; then
    echo "❌ No production Swift sources found under $tree — cannot check the boundary"
    return 2
  fi

  local hits
  if hits=$( (cd "$tree" && grep -nE "$WRITE_SURFACE" "${sources[@]}") 2>/dev/null ); then
    echo "❌ Store-internal write surface referenced outside WorkoutChatLog/Storage/:"
    echo "$hits" | sed 's/^/   /'
    echo "   Every workout write must go through the typed store API (save/saveCardio/…)."
    status=1
  fi

  if hits=$( (cd "$tree" && grep -nE 'SQLiteDB\(' "${sources[@]}") 2>/dev/null \
               | grep -v '^WorkoutChatLog/Shared/' ); then
    echo "❌ SQLiteDB constructed outside Storage/ (and outside the Shared read path):"
    echo "$hits" | sed 's/^/   /'
    echo "   Feature code gets its connection through WorkoutStore, never directly."
    status=1
  fi

  return $status
}

# Build a minimal fixture tree: one clean file per dir, plus an optional
# planted file at $2 with content $3.
make_fixture() {
  local sandbox="$1" plant_path="${2:-}" plant_content="${3:-}"
  mkdir -p "$sandbox/WorkoutChatLog/Features" "$sandbox/WorkoutChatLog/Shared" \
           "$sandbox/WorkoutChatLog/Storage" "$sandbox/WorkoutWidget"
  echo 'let ok = store.setHistory()' > "$sandbox/WorkoutChatLog/Features/Clean.swift"
  echo 'let ok = true' > "$sandbox/WorkoutWidget/Clean.swift"
  # Storage may (and does) use the raw surface — must never trip the check.
  echo 'let x = db.transaction { try insertExercise(slug: s) }' \
    > "$sandbox/WorkoutChatLog/Storage/Store.swift"
  if [[ -n "$plant_path" ]]; then
    mkdir -p "$sandbox/$(dirname "$plant_path")"
    echo "$plant_content" > "$sandbox/$plant_path"
  fi
}

# One self-test case: expect check_tree on the fixture to exit with $1.
expect() {
  local want="$1" label="$2" plant_path="${3:-}" plant_content="${4:-}"
  local sandbox
  sandbox="$(mktemp -d)"
  make_fixture "$sandbox" "$plant_path" "$plant_content"
  local got=0
  check_tree "$sandbox" > /dev/null 2>&1 || got=$?
  rm -rf "$sandbox"
  if [[ "$got" -ne "$want" ]]; then
    echo "❌ Guard self-test failed: $label (expected exit $want, got $got)"
    echo "   The check itself has regressed — fix the script before trusting a green run."
    exit 1
  fi
}

self_test() {
  expect 0 "clean tree passes"
  expect 1 "raw connection access is caught" \
    "WorkoutChatLog/Features/Bad.swift" 'let x = store.db'
  expect 1 "registry writer call is caught" \
    "WorkoutChatLog/Features/Bad.swift" 'let id = try store.insertExercise(slug: s)'
  expect 1 "resolveOrCreateExercise is caught" \
    "WorkoutChatLog/Features/Bad.swift" '_ = try store.resolveOrCreateExercise(name)'
  expect 1 "insertAlias is caught" \
    "WorkoutChatLog/Features/Bad.swift" 'try store.insertAlias(a, exerciseID: id)'
  expect 1 "SQLiteDB construction in Features is caught" \
    "WorkoutChatLog/Features/Bad.swift" 'let db = try SQLiteDB(path: p)'
  expect 1 "SQLiteDB construction in the widget target is caught" \
    "WorkoutWidget/Bad.swift" 'let db = try SQLiteDB(path: p)'
  expect 0 "Shared may construct its read-only SQLiteDB" \
    "WorkoutChatLog/Shared/Reader.swift" 'let db = try SQLiteDB(path: url.path)'
  echo "✅ Guard self-test passed (7 fixtures)"
}

self_test

if ! check_tree "$ROOT"; then
  exit 1
fi

echo "✅ Store write-path boundary intact: raw connection + registry writers only referenced under WorkoutChatLog/Storage/"
